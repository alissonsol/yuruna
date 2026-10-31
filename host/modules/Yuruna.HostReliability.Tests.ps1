<#PSScriptInfo
.VERSION 2026.10.31
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
    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'test/modules/Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.DriverSource.psm1') -Force -DisableNameChecking
    function Get-SourceFunction {
        param([string]$Path, [string]$Name)
        # A driver root's functions are found in whichever of its files defines them.
        return (Get-YurunaSourceFunction -Path (Join-Path $script:RepoRoot $Path) -Name $Name)
    }
    function Format-YurunaOperatorMessage { param($Key, $Arguments) return $Key }
    # Runs driver functions lifted from source beside stand-ins for what they
    # call, so no hypervisor or host state is touched.
    function Invoke-LiftedDriverFunction {
        param([string]$Driver, [string[]]$Name, [scriptblock]$Stubs, [scriptblock]$Call)
        $source = ($Name | ForEach-Object { Get-SourceFunction -Path "host/$Driver/modules/Yuruna.Host.psm1" -Name $_ }) -join "`n"
        return (& { . $Stubs; . ([scriptblock]::Create($source)); & $Call })
    }
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
        $prior = Save-YurunaTestEnvironment -Name 'YURUNA_CACHING_PROXY_SERVICE_IP'
        try {
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = ' 192.0.2.5 '
            $script:CacheReachable = $true
            Resolve-CacheHostIp | Should -Be '192.0.2.5'
            $script:CacheReachable = $false
            Resolve-CacheHostIp | Should -BeNullOrEmpty
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = 'invalid'
            Resolve-CacheHostIp | Should -BeNullOrEmpty
        } finally { Restore-YurunaTestEnvironment -Saved $prior }
    }
}
Describe 'Cache exposure follows the configured guest network' {
    It 'classifies UTM <Case> without changing host networking' -ForEach @(
        @{ Case = 'bridged attachment'; Present = $true; Readable = $true; Mode = 'Bridged'; Expected = $true },
        @{ Case = 'shared NAT attachment'; Present = $true; Readable = $true; Mode = 'Shared'; Expected = $false },
        @{ Case = 'unknown attachment'; Present = $true; Readable = $true; Mode = 'Unknown'; Expected = $false },
        @{ Case = 'missing network mode'; Present = $true; Readable = $true; Mode = ''; Expected = $false },
        @{ Case = 'unreadable bridged bundle'; Present = $true; Readable = $false; Mode = 'Bridged'; Expected = $false },
        @{ Case = 'missing bundle'; Present = $false; Readable = $false; Mode = ''; Expected = $false }
    ) {
        . ([scriptblock]::Create((Get-SourceFunction 'host/macos.utm/modules/Yuruna.Host.psm1' 'Test-CacheVMOnExternalNetwork')))
        function Get-UtmBundleNetwork {
            param($VMName)
            $VMName | Should -Be 'custom-cache'
            if ($Present) { return [pscustomobject]@{ Readable = $Readable; Mode = $Mode } }
            return $null
        }
        function Get-MacDefaultRouteInterface { throw 'The current uplink cannot describe an existing VM.' }
        Test-CacheVMOnExternalNetwork -VMName 'custom-cache' | Should -Be $Expected
    }

    It 'classifies KVM <Case> using the actual first NIC and network definition' -ForEach @(
        @{ Case = 'custom NAT'; Domain = '<interface type="network"><source network="custom-nat"/></interface>'; Network = '<network><forward mode="nat"/></network>'; Expected = $false },
        @{ Case = 'custom routed network'; Domain = '<interface type="network"><source network="custom-route"/></interface>'; Network = '<network><forward mode="route"/></network>'; Expected = $false },
        @{ Case = 'custom isolated network'; Domain = '<interface type="network"><source network="custom-isolated"/></interface>'; Network = '<network><bridge name="virbr7"/></network>'; Expected = $false },
        @{ Case = 'custom host bridge'; Domain = '<interface type="network"><source network="custom-bridge"/></interface>'; Network = '<network><forward mode="bridge"/></network>'; Expected = $true },
        @{ Case = 'a bridge named default'; Domain = '<interface type="network"><source network="default"/></interface>'; Network = '<network><forward mode="bridge"/></network>'; Expected = $true },
        @{ Case = 'reordered network attributes'; Domain = '<interface type="network"><source portgroup="cache" network="custom-bridge"/></interface>'; Network = "<network><forward managed='yes' mode='bridge'/></network>"; Expected = $true },
        @{ Case = 'a direct host bridge NIC'; Domain = '<interface type="bridge"><source bridge="br0"/></interface>'; Network = ''; Expected = $true },
        @{ Case = 'a host bridge NIC without its source'; Domain = '<interface type="bridge"/>'; Network = ''; Expected = $false },
        @{ Case = 'a NAT primary NIC before a bridge'; Domain = '<interface type="network"><source network="custom-nat"/></interface><interface type="bridge"><source bridge="br0"/></interface>'; Network = '<network><forward mode="nat"/></network>'; Expected = $false },
        @{ Case = 'an unsupported direct NIC'; Domain = '<interface type="direct"><source dev="eth0"/></interface>'; Network = ''; Expected = $false },
        @{ Case = 'a missing NIC'; Domain = ''; Network = ''; Expected = $false }
    ) {
        foreach ($name in 'Test-CacheVMOnExternalNetwork', 'Test-YurunaLibvirtNetworkIsBridgeMode') {
            . ([scriptblock]::Create((Get-SourceFunction 'host/ubuntu.kvm/modules/Yuruna.Host.psm1' $name)))
        }
        $script:NetworkQueries = @()
        function Get-VirshDomState { param($VMName); $VMName | Should -Be 'custom-cache'; return 'running' }
        function Invoke-Virsh {
            param($VirshArgs)
            $global:LASTEXITCODE = 0
            if ($VirshArgs[0] -eq 'dumpxml') {
                $VirshArgs[1] | Should -Be 'custom-cache'
                return "<domain><devices>$Domain</devices></domain>"
            }
            if ($VirshArgs[0] -ne 'net-dumpxml') { throw 'Unexpected native query.' }
            $script:NetworkQueries += $VirshArgs[1]
            return $Network
        }
        Test-CacheVMOnExternalNetwork -VMName 'custom-cache' | Should -Be $Expected
        if ($Domain -match 'network="([^"]+)"') {
            $script:NetworkQueries | Should -Be @($Matches[1])
        } else {
            $script:NetworkQueries | Should -BeNullOrEmpty
        }
    }

    It 'refuses KVM LAN-direct exposure after <Case>' -ForEach @(
        @{ Case = 'missing domain'; Stage = 'state'; ExitCode = 0; Xml = '' },
        @{ Case = 'failed domain query'; Stage = 'domain'; ExitCode = 1; Xml = '<domain><devices><interface type="bridge"><source bridge="br0"/></interface></devices></domain>' },
        @{ Case = 'malformed domain XML'; Stage = 'domain'; ExitCode = 0; Xml = '<domain><devices>' },
        @{ Case = 'failed network query with bridge-shaped output'; Stage = 'network'; ExitCode = 1; Xml = '<network><forward mode="bridge"/></network>' },
        @{ Case = 'malformed network XML'; Stage = 'network'; ExitCode = 0; Xml = '<network><forward mode="bridge"/>' },
        @{ Case = 'missing network XML'; Stage = 'network'; ExitCode = 0; Xml = '' }
    ) {
        foreach ($name in 'Test-CacheVMOnExternalNetwork', 'Test-YurunaLibvirtNetworkIsBridgeMode') {
            . ([scriptblock]::Create((Get-SourceFunction 'host/ubuntu.kvm/modules/Yuruna.Host.psm1' $name)))
        }
        function Get-VirshDomState { param($VMName); if ($Stage -ne 'state') { return 'running' }; return $null }
        function Invoke-Virsh {
            param($VirshArgs)
            if ($Stage -eq 'state') { throw 'No native query is allowed for an absent domain.' }
            if ($VirshArgs[0] -eq 'dumpxml' -and $Stage -ne 'domain') {
                $global:LASTEXITCODE = 0
                return '<domain><devices><interface type="network"><source network="cache"/></interface></devices></domain>'
            }
            $global:LASTEXITCODE = $ExitCode
            return $Xml
        }
        Test-CacheVMOnExternalNetwork -VMName 'custom-cache' | Should -BeFalse
    }
}
Describe 'Cache VM address reads agree across providers' {
    It 'returns the recorded guest address on <Platform>' -ForEach @(
        @{ Platform = 'windows.hyper-v' }, @{ Platform = 'macos.utm' }, @{ Platform = 'ubuntu.kvm' }
    ) {
        . ([scriptblock]::Create((Get-SourceFunction "host/$Platform/modules/Yuruna.Host.psm1" 'Get-CachingProxyServiceVmIp')))
        function Read-CachingProxyServiceState { return @{ ipAddress = '192.0.2.25' } }
        function Test-Ipv4Address { param($Address); return $Address -eq '192.0.2.25' }
        function Test-IpAddress { param($Address); return $Address -eq '192.0.2.25' }
        function Get-VMIp { throw 'The recorded address must not trigger a live query.' }
        Get-CachingProxyServiceVmIp | Should -Be '192.0.2.25'
    }

    It 'does not use invalid recorded address <Address> on <Platform>' -ForEach @(
        @{ Platform = 'windows.hyper-v'; Address = '' }, @{ Platform = 'windows.hyper-v'; Address = 'not-an-address' },
        @{ Platform = 'macos.utm'; Address = '' }, @{ Platform = 'macos.utm'; Address = 'not-an-address' },
        @{ Platform = 'ubuntu.kvm'; Address = '' }, @{ Platform = 'ubuntu.kvm'; Address = 'not-an-address' }
    ) {
        . ([scriptblock]::Create((Get-SourceFunction "host/$Platform/modules/Yuruna.Host.psm1" 'Get-CachingProxyServiceVmIp')))
        function Read-CachingProxyServiceState { return @{ ipAddress = $Address } }
        function Test-Ipv4Address { return $false }
        function Test-IpAddress { return $false }
        function Get-VMIp { param($VMName); $VMName | Should -Be 'yuruna-caching-proxy-service'; return $null }
        Get-CachingProxyServiceVmIp | Should -BeNullOrEmpty
    }
}
Describe 'Windows guest bootstrap inputs agree across hosts' {
    It 'forwards configured clone URLs with the token on <Platform>' -ForEach @(
        @{ Platform = 'windows.hyper-v' }, @{ Platform = 'ubuntu.kvm' }, @{ Platform = 'macos.utm' }
    ) {
        $path = Join-Path $script:RepoRoot "host/$Platform/guest.windows.11/New-VM.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $resolve = $ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$ghSource'
        }, $true)
        $bootstrap = $ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'New-WindowsGuestBootstrap'
        }, $true)
        function Get-YurunaGitHubSource {
            param($RepoRoot)
            return @{ Token = 'fixture-token'; FrameworkUrl = 'https://example.com/framework'; ProjectUrl = 'https://example.com/project' }
        }
        function New-WindowsGuestBootstrap {
            param($RepoRoot, $StatusServiceIp, $StatusServicePort, $HostId, $CachingProxyIp, $GhToken, $FrameworkUrl, $ProjectUrl)
            return @{ Token = $GhToken; FrameworkUrl = $FrameworkUrl; ProjectUrl = $ProjectUrl }
        }
        $result = & ([scriptblock]::Create($resolve.Extent.Text + "`n" + $bootstrap.Extent.Text))
        $result.Token | Should -Be 'fixture-token'
        $result.FrameworkUrl | Should -Be 'https://example.com/framework'
        $result.ProjectUrl | Should -Be 'https://example.com/project'
    }
    It 'loads the UTM driver before discovering a standalone bridged interface' {
        $source = Get-Content (Join-Path $script:RepoRoot 'host/macos.utm/guest.windows.11/New-VM.ps1') -Raw
        $start = $source.IndexOf('# --- REGION: Resolve network interface for Bridged mode')
        $end = $source.IndexOf('# --- REGION:', $start + 15)
        $body = $source.Substring($start, $end - $start).Replace('$PSScriptRoot', '$script:FixtureGuestRoot')
        function Import-Module { $script:DriverReady = $true }
        function Get-MacDefaultRouteInterface {
            if (-not $script:DriverReady) { throw 'Host driver has not loaded.' }
            return 'en0'
        }
        $script:DriverReady = $false
        $script:FixtureGuestRoot = Join-Path $script:RepoRoot 'host/macos.utm/guest.windows.11'
        $NetworkMode = 'Bridged'
        $BridgeInterface = ''
        . ([scriptblock]::Create($body))
        $BridgeInterface | Should -Be 'en0'
    }
}
Describe 'Standalone KVM Ubuntu cache selection follows the shared policy' {
    BeforeAll {
        $source = Get-Content (Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/New-UbuntuServerVM.ps1') -Raw
        $start = $source.IndexOf('# --- REGION: Detect the caching-proxy service')
        $end = $source.IndexOf('# --- REGION:', $start + 15)
        $script:CacheSelection = [scriptblock]::Create('[CmdletBinding()]param([AllowEmptyString()][string]$CachingProxyServiceUrl)' +
            "`n" + $source.Substring($start, $end - $start) + "`nreturn `$CachingProxyServiceUrl")
    }
    BeforeEach {
        $script:CacheProbeCalls = 0
        $script:CacheProbeUrl = ''
        $script:CacheState = 'absent'
        function Test-CachingProxyServiceAvailable { $script:CacheProbeCalls++; return $script:CacheProbeUrl }
        function Get-VMState { return $script:CacheState }
    }
    It 'discovers an unbound URL from the host cache probe' {
        $script:CacheProbeUrl = 'http://192.0.2.8:3128'
        & $script:CacheSelection | Should -Be 'http://192.0.2.8:3128'
        $script:CacheProbeCalls | Should -Be 1
    }
    It 'preserves an explicitly bound <Case> without probing' -ForEach @(
        @{ Case = 'empty direct-fetch opt-out'; Url = '' },
        @{ Case = 'runner-selected URL'; Url = 'http://192.0.2.9:3128' }
    ) {
        & $script:CacheSelection -CachingProxyServiceUrl $Url | Should -Be $Url
        $script:CacheProbeCalls | Should -Be 0
    }
    It 'permits direct fetching when the cache is <State>' -ForEach @(
        @{ State = 'absent' }, @{ State = 'stopped' }
    ) {
        $script:CacheState = $State
        & $script:CacheSelection | Should -BeNullOrEmpty
        $script:CacheProbeCalls | Should -Be 1
    }
    It 'fails before apt rendering when the running cache cannot be reached' {
        $script:CacheState = 'running'
        $ErrorActionPreference = 'Stop'
        { & $script:CacheSelection } | Should -Throw '*host.kvm_running_cache_unreachable*'
    }
}
# The agent spares the origin the bytes, not the publisher its say on them.
Describe 'An image the download agent serves is verified like a direct download' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.UbuntuImage.psm1') -Force -DisableNameChecking
        $script:Iso = 'ubuntu-26.04.1-live-server-amd64.iso'
        $script:Base = 'host.ubuntu.kvm.guest.ubuntu.server.26'
    }
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Dir
        Set-Content -LiteralPath (Join-Path $script:Dir 'downloaded.iso') -Value 'agent bytes'
        Set-Content -LiteralPath (Join-Path $script:Dir "$($script:Base).iso") -Value 'previous bytes'
        $iso = $script:Iso
        Mock -ModuleName Yuruna.UbuntuImage Invoke-DownloadAgentFirst {
            @{ BaseUrl = 'http://192.0.2.10:8090'; Result = @{ outcome = 'downloaded'; filename = $iso; sourceUrl = "https://releases.example.invalid/26.04/$iso"; lastModified = '' } }
        }.GetNewClosure()
    }
    It 'checks the publisher checksum list beside the origin, and keeps the old image when it fails' {
        Mock -ModuleName Yuruna.UbuntuImage Test-UbuntuServerImageChecksum { $false }
        { Save-UbuntuServerImage -ReleaseCodename resolute -Arch amd64 -DownloadDir $script:Dir -BaseImageName $script:Base } | Should -Throw
        Should -Invoke -ModuleName Yuruna.UbuntuImage Test-UbuntuServerImageChecksum -Times 1 -Exactly -ParameterFilter { $ChecksumUrl -ceq 'https://releases.example.invalid/26.04/SHA256SUMS' }
        Get-Content -LiteralPath (Join-Path $script:Dir "$($script:Base).iso") | Should -Be 'previous bytes'
        Test-Path -LiteralPath (Join-Path $script:Dir 'downloaded.iso') | Should -BeFalse
    }
    It 'records a failed checksum as an integrity failure for the runner to file' {
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
        $record = Join-Path $script:Dir 'provision/guest.GetImage.json'
        $prior = Save-YurunaTestEnvironment -Name 'YURUNA_PROVISION_RESULT'
        $env:YURUNA_PROVISION_RESULT = $record
        try {
            Mock -ModuleName Yuruna.UbuntuImage Test-UbuntuServerImageChecksum { $false }
            { Save-UbuntuServerImage -ReleaseCodename resolute -Arch amd64 -DownloadDir $script:Dir -BaseImageName $script:Base } | Should -Throw
            $result = Read-YurunaProvisionResult -Path $record
            $result.kind | Should -Be 'integrity'
            $result.failureClass | Should -Be 'source_integrity' -Because 'the same bytes fail the same way, so a retry is no repair'
        } finally { Restore-YurunaTestEnvironment -Saved $prior }
    }
    It 'writes no sentinel for a swap that did not put the new image in place' {
        Mock -ModuleName Yuruna.UbuntuImage Test-UbuntuServerImageChecksum { $true }
        Mock -ModuleName Yuruna.UbuntuImage Publish-YurunaBaseImage { throw 'the base image is in use' }
        { Save-UbuntuServerImage -ReleaseCodename resolute -Arch amd64 -DownloadDir $script:Dir -BaseImageName $script:Base 6>$null } | Should -Throw
        Test-Path -LiteralPath (Join-Path $script:Dir "$($script:Base).txt") | Should -BeFalse -Because 'the skip guard would trust bytes that are not there'
    }
    It 'uses the image once the publisher checksum list vouches for it' {
        Mock -ModuleName Yuruna.UbuntuImage Test-UbuntuServerImageChecksum { $true }
        Save-UbuntuServerImage -ReleaseCodename resolute -Arch amd64 -DownloadDir $script:Dir -BaseImageName $script:Base 6>$null | Should -Be 'downloaded'
        Get-Content -LiteralPath (Join-Path $script:Dir "$($script:Base).iso") | Should -Be 'agent bytes'
    }
    It 'refuses an image whose origin neither the agent nor the publisher listing names' {
        $iso = $script:Iso
        Mock -ModuleName Yuruna.UbuntuImage Invoke-DownloadAgentFirst {
            @{ BaseUrl = 'http://192.0.2.10:8090'; Result = @{ outcome = 'downloaded'; filename = $iso; sourceUrl = "agent:http://192.0.2.10:8090/$iso"; lastModified = '' } }
        }.GetNewClosure()
        Mock -ModuleName Yuruna.UbuntuImage Resolve-UbuntuServerImage { $null }
        Mock -ModuleName Yuruna.UbuntuImage Test-UbuntuServerImageChecksum { $true }
        { Save-UbuntuServerImage -ReleaseCodename resolute -Arch amd64 -DownloadDir $script:Dir -BaseImageName $script:Base -WarningAction SilentlyContinue } | Should -Throw
        Should -Invoke -ModuleName Yuruna.UbuntuImage Test-UbuntuServerImageChecksum -Times 0 -Exactly
        Get-Content -LiteralPath (Join-Path $script:Dir "$($script:Base).iso") | Should -Be 'previous bytes'
    }
}

Describe 'Image lookup includes every installed guest builder' {
    It 'resolves Ubuntu 26 and the UTM macOS image without loading a hypervisor' {
        foreach ($platform in 'ubuntu.kvm', 'macos.utm', 'windows.hyper-v') {
            $source = Get-YurunaSourceText -Path (Join-Path $script:RepoRoot "host/$platform/modules/Yuruna.Host.psm1")
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
Describe 'Orphan cleanup reports owned-operation failures across providers' {
    It 'returns <Expected> after <Case> while attempting every orphan on <Platform>' -ForEach @(
        @{ Platform = 'macos.utm'; Case = 'successful deletion'; FailFirst = 0; Expected = 0 }
        @{ Platform = 'macos.utm'; Case = 'one failed deletion'; FailFirst = 1; Expected = 1 }
        @{ Platform = 'ubuntu.kvm'; Case = 'successful deletion'; FailFirst = 0; Expected = 0 }
        @{ Platform = 'ubuntu.kvm'; Case = 'one failed deletion'; FailFirst = 1; Expected = 1 }
        @{ Platform = 'windows.hyper-v'; Case = 'successful deletion'; FailFirst = 0; Expected = 0 }
        @{ Platform = 'windows.hyper-v'; Case = 'one failed deletion'; FailFirst = 1; Expected = 1 }
    ) {
        $source = Get-Content (Join-Path $script:RepoRoot "host/$Platform/Remove-OrphanedVMFiles.ps1") -Raw
        $region = $source.Substring($source.IndexOf('# --- REGION: Delete orphaned VM artifacts', [StringComparison]::Ordinal))
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        foreach ($name in 'first', 'second') { Set-Content -LiteralPath (Join-Path $root $name) -Value 'owned fixture' }
        $fixture = @'
param([string]$Root, [int]$FailFirst)
$ErrorActionPreference = 'Stop'
$Force = $true
$errors = 0
$orphanedFiles = @((Join-Path $Root 'first'), (Join-Path $Root 'second'))
$orphanedItems = @($orphanedFiles | ForEach-Object { @{ Name = [IO.Path]::GetFileName($_); Path = $_; Size = 1 } })
$scanPaths = @()
$virshUri = 'fixture'
$utmctlPath = 'fixture'
$global:LASTEXITCODE = 17
function Format-YurunaOperatorMessage { param($Key, $Arguments, $FormatValues, $FormatBindings); return $Key }
function Write-CleanupMessage { param($Message) }
function Get-UTMBundleUUID { return 'fixture-uuid' }
function Invoke-OrphanSweepUtmctl { return @{ Complete = $true; ExitCode = 0 } }
function Get-OrphanSweepRegistration { $global:LASTEXITCODE = 17; return 'absent' }
function virsh { $global:LASTEXITCODE = 1; return 'Domain not found' }
function Remove-Item {
    param($LiteralPath, [switch]$Force, [switch]$Recurse, $ErrorAction)
    Add-Content -LiteralPath (Join-Path $Root 'attempts') -Value ([IO.Path]::GetFileName($LiteralPath))
    if ($FailFirst -eq 1 -and [IO.Path]::GetFileName($LiteralPath) -eq 'first') { throw 'fixture refusal' }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force:$Force -Recurse:$Recurse -ErrorAction $ErrorAction
}
'@
        $path = Join-Path $root 'sweep.ps1'
        [IO.File]::WriteAllText($path, $fixture + "`n" + $region)
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $path -Root $root -FailFirst $FailFirst 2>&1
        $code = $LASTEXITCODE
        $code | Should -Be $Expected -Because (($output | Out-String).Trim())
        @(Get-Content -LiteralPath (Join-Path $root 'attempts')) | Should -Be @('first', 'second')
        Test-Path -LiteralPath (Join-Path $root 'first') | Should -Be ([bool]$FailFirst)
        Test-Path -LiteralPath (Join-Path $root 'second') | Should -BeFalse
    }

    It 'preserves an ACL maintenance failure when no orphan needs deletion' {
        $source = Get-Content (Join-Path $script:RepoRoot 'host/windows.hyper-v/Remove-OrphanedVMFiles.ps1') -Raw
        $region = $source.Substring($source.IndexOf('# --- REGION: Strip stale per-VM ACEs from kept base images', [StringComparison]::Ordinal))
        $fixture = @'
$protectedFiles = @('protected-base-image')
$orphanedFiles = @()
function Remove-OrphanedVMFileAccess { throw 'fixture ACL refusal' }
function Format-YurunaOperatorMessage { param($Key, $Arguments); return $Key }
function Write-CleanupMessage { param($Message) }
'@
        $path = Join-Path $TestDrive 'acl-maintenance.ps1'
        [IO.File]::WriteAllText($path, $fixture + "`n" + $region)
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $path 2>&1
        $code = $LASTEXITCODE
        $code | Should -Be 1
        ($output | Out-String) | Should -Match 'host.operator_a2a687435a04d1fc'
    }
}
Describe 'Orphan folder sizing preserves literal paths and Int64 results' {
    BeforeAll {
        . ([scriptblock]::Create((Get-SourceFunction 'host/modules/Yuruna.VMCleanup.psm1' 'Get-VMFolderSize')))
    }
    It 'returns Int64 zero for an <Case> folder' -ForEach @(
        @{ Case = 'empty'; Create = $true }
        @{ Case = 'absent'; Create = $false }
    ) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        if ($Create) { $null = New-Item -ItemType Directory -Path $path }
        $size = Get-VMFolderSize -Path $path
        $size | Should -BeOfType ([int64])
        $size | Should -Be 0
    }
    It 'sums nested files without interpreting bracketed names as wildcards' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path = Join-Path $root 'guest[1]'
        $nested = Join-Path $path 'nested'
        $lookalike = Join-Path $root 'guest1'
        $null = New-Item -ItemType Directory -Path $nested, $lookalike -Force
        [IO.File]::WriteAllBytes((Join-Path $path 'first'), [byte[]]@(1, 2, 3))
        [IO.File]::WriteAllBytes((Join-Path $nested 'second'), [byte[]]@(4, 5, 6, 7, 8))
        [IO.File]::WriteAllBytes((Join-Path $lookalike 'other'), [byte[]]::new(97))
        $size = Get-VMFolderSize -Path $path
        $size | Should -BeOfType ([int64])
        $size | Should -Be 8
    }
}
Describe 'VM provisioning fails immediately on non-terminating cmdlet errors' {
    It 'halts each affected builder before a later completion step' {
        $paths = Get-ChildItem (Join-Path $script:RepoRoot 'host/macos.utm/guest.*/New-VM.ps1')
        $paths += Get-ChildItem (Join-Path $script:RepoRoot 'host/windows.hyper-v/guest.*/New-VM.ps1')
        foreach ($path in $paths) {
            # A per-release wrapper that hands its work to the host's shared Ubuntu builder is judged by that builder.
            $target = $path.FullName
            $shared = Join-Path (Split-Path -Parent $path.DirectoryName) 'modules/New-UbuntuServerVM.ps1'
            if ((Get-Content -Raw -LiteralPath $target) -match 'New-UbuntuServerVM\.ps1' -and (Test-Path -LiteralPath $shared)) { $target = $shared }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$null)
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
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
        . ([scriptblock]::Create((Get-SourceFunction 'host/windows.hyper-v/modules/Yuruna.Host.psm1' 'Add-PortMap')))
        function Test-Ipv4Address { return $true }
        function Test-IsAdministrator { return $true }
        function Get-PortMapStatePath { return (Join-Path $TestDrive 'port-map.json') }
        function Get-HyperVPortMapPort { return [int[]]@() }
        function Remove-SinglePortMap { param($Port) $null = $Port }
        function Stop-WindowsCachingProxyServiceForwarder { return $true }
        function Add-CachingProxyServiceFirewallRule { }
        function Start-WindowsCachingProxyServiceForwarder { return @{ Success = $false } }
        function netsh { }
        $output = @(Add-PortMap -VMIp '192.0.2.8' -Owner 'caching-proxy-service' -Port 80 -ProxyProtocolPort 80 -Confirm:$false -WarningAction SilentlyContinue)
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
        $start = $source.IndexOf('# --- REGION: Seek the base image')
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
        $source = Get-YurunaSourceText -Path (Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1')
        $start = $source.IndexOf('$script:YurunaDhcpCapture = $null')
        $end = $source.IndexOf('$script:YurunaDhcpTrail', $start)
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

# --- REGION: Download agent provenance preserves local fingerprints
Describe 'Download agent provenance preserves local fingerprints' {
    It 'keeps <Artifact> current without an origin URL on <Platform>' -ForEach @(
        @{ Platform = 'macos.utm'; Artifact = 'al2023-test.arm64.qcow2'; MissingSource = '' },
        @{ Platform = 'ubuntu.kvm'; Artifact = 'al2023-test.x86_64.qcow2'; MissingSource = ' ' },
        @{ Platform = 'windows.hyper-v'; Artifact = 'al2023-test.hyperv.zip'; MissingSource = $null }
    ) {
        . ([scriptblock]::Create((Get-SourceFunction 'host/modules/Yuruna.Image.psm1' 'Invoke-DownloadAgentFirst')))
        . ([scriptblock]::Create((Get-SourceFunction 'host/modules/Yuruna.HostDownload.psm1' 'Write-ImageSentinel')))
        function Resolve-DownloadAgentEndpoint { return 'http://192.0.2.10:8090/' }
        function Invoke-WebRequest { throw 'Agent metadata must not trigger an origin probe.' }
        function Request-DownloadAgentImage {
            param($BaseUrl, $HostType, $ImageKey, $Arch, $Variant, $StagingPath, $DeadlineSeconds,
                $ExpectedFilenamePattern, $LocalFilename, $LocalByteCount)
            if ($LocalFilename) {
                $LocalFilename | Should -BeExactly $Artifact
                $LocalByteCount | Should -Be 4
                return @{ outcome = 'skipped' }
            }
            [IO.File]::WriteAllBytes($StagingPath, [byte[]]@(1, 2, 3, 4))
            return @{ outcome = 'downloaded'; filename = $Artifact; sourceUrl = $MissingSource; lastModified = '' }
        }
        $baseImage = Join-Path $TestDrive "$Platform.base-image"
        $originFile = Join-Path $TestDrive "$Platform.origin.txt"
        $request = @{
            HostType = $Platform; ImageKey = 'guest.amazon.linux.2023'; Arch = 'arm64'
            StagingPath = (Join-Path $TestDrive "$Platform.download"); BaseImageFile = $baseImage; OriginFile = $originFile
        }
        $first = Invoke-DownloadAgentFirst @request
        $first.Result.outcome | Should -BeExactly 'downloaded'
        $first.Result.sourceUrl | Should -BeExactly "agent:http://192.0.2.10:8090/$Artifact"
        Move-Item -LiteralPath $request.StagingPath -Destination $baseImage
        Write-ImageSentinel -SourceUrl $first.Result.sourceUrl -OriginFile $originFile -SizeBytes 4 `
            -LastModified $first.Result.lastModified -Confirm:$false
        $lines = @(Get-Content -LiteralPath $originFile)
        $lines[0] | Should -BeExactly $Artifact
        $lines[2] | Should -BeExactly '4'
        (Invoke-DownloadAgentFirst @request).Result.outcome | Should -BeExactly 'skipped'
    }

    It 'preserves the supplied origin URL and Last-Modified metadata' {
        . ([scriptblock]::Create((Get-SourceFunction 'host/modules/Yuruna.Image.psm1' 'Invoke-DownloadAgentFirst')))
        function Resolve-DownloadAgentEndpoint { return 'http://192.0.2.10:8090' }
        function Request-DownloadAgentImage {
            return @{ outcome = 'downloaded'; filename = 'al2023-test.qcow2';
                sourceUrl = 'https://cdn.example.invalid/al2023-test.qcow2'; lastModified = 'Fri, 09 Oct 2026 12:00:00 GMT' }
        }
        $result = Invoke-DownloadAgentFirst -HostType 'ubuntu.kvm' -ImageKey 'guest.amazon.linux.2023' -Arch 'amd64' `
            -StagingPath (Join-Path $TestDrive 'origin.download') `
            -BaseImageFile (Join-Path $TestDrive 'origin.base-image') -OriginFile (Join-Path $TestDrive 'origin.origin.txt')
        $result.Result.sourceUrl | Should -BeExactly 'https://cdn.example.invalid/al2023-test.qcow2'
        $result.Result.lastModified | Should -BeExactly 'Fri, 09 Oct 2026 12:00:00 GMT'
    }
}

Describe 'Get-Image failures carry the class their stage recorded' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
        $script:ProvisionModule = Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1'
        function New-GetImageFixture {
            param([string]$Body)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $folder = Join-Path $root 'host/fixture/guest.fixture'
            $null = New-Item -ItemType Directory -Path $folder -Force
            Set-Content -LiteralPath (Join-Path $folder 'Get-Image.ps1') -Value $Body
            return $root
        }
        function Invoke-FixtureGetImage {
            param([string]$Root)
            return (Invoke-GetImage -HostSubdir 'host/fixture' -GuestKey 'guest.fixture' -RepoRoot $Root -Force `
                -ResolveImagePath { param($GuestKey) $null = $GuestKey; $null } -WriteLine { param($Line) $null = $Line } -Confirm:$false)
        }
    }
    BeforeEach {
        $script:priorLogDir = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $env:YURUNA_LOG_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:priorLogDir }

    It 'files the class the stage recorded' {
        $root = New-GetImageFixture -Body "Import-Module '$($script:ProvisionModule)' -DisableNameChecking; Write-YurunaProvisionResult -Kind integrity -Message 'checksum mismatch'; exit 1"
        $r = Invoke-FixtureGetImage -Root $root
        $r.success | Should -BeFalse
        $r.failureClass | Should -Be 'source_integrity'
        $r.kind | Should -Be 'integrity'
        $env:YURUNA_PROVISION_RESULT | Should -BeNullOrEmpty -Because 'the path is named for the stage only'
    }
    It 'keeps the network default for a stage that recorded nothing, even with a record left from an earlier run' {
        $stale = Join-Path $env:YURUNA_LOG_DIR 'provision/guest.fixture.GetImage.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $stale) -Force
        Set-Content -LiteralPath $stale -Value '{"kind":"integrity","message":"old"}'
        $root = New-GetImageFixture -Body 'exit 1'
        $r = Invoke-FixtureGetImage -Root $root
        $r.failureClass | Should -Be 'network_timeout'
        $r.kind | Should -Be ''
    }
    It 'files a guest this host has no Get-Image for as a plan the host cannot run' {
        $r = Invoke-GetImage -HostSubdir 'host/fixture' -GuestKey 'guest.absent' -RepoRoot $TestDrive -Force `
            -ResolveImagePath { param($GuestKey) $null = $GuestKey; $null } -WriteLine { param($Line) $null = $Line } -Confirm:$false
        $r.failureClass | Should -Be 'plan_invalid'
    }
    It 'reads no record that names an unknown kind' {
        $path = Join-Path $TestDrive 'odd.json'
        Set-Content -LiteralPath $path -Value '{"kind":"cosmic-ray"}'
        Read-YurunaProvisionResult -Path $path | Should -BeNullOrEmpty
    }
}

Describe 'Publish-YurunaBaseImage proves the swap before a sentinel can vouch for it' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.Image.psm1') -Force -DisableNameChecking
    }
    BeforeEach {
        $script:PubDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:PubDir
        $script:Download = Join-Path $script:PubDir 'downloaded.iso'
        $script:BaseFile = Join-Path $script:PubDir 'base.iso'
        $script:Previous = Join-Path $script:PubDir 'base.previous.iso'
        [IO.File]::WriteAllText($script:Download, 'new bytes')
        [IO.File]::WriteAllText($script:BaseFile, 'old bytes')
    }
    It 'keeps the old image as the previous one and publishes the download' {
        Publish-YurunaBaseImage -DownloadFile $script:Download -BaseImageFile $script:BaseFile -PreviousFile $script:Previous -ExpectedSize 9 -Confirm:$false | Should -BeTrue
        [IO.File]::ReadAllText($script:BaseFile) | Should -Be 'new bytes'
        [IO.File]::ReadAllText($script:Previous) | Should -Be 'old bytes'
        Test-Path -LiteralPath "$($script:BaseFile).publish.lock" | Should -BeFalse -Because 'the lock is released'
    }
    It 'puts the previous image back when the download cannot be moved into place' {
        Remove-Item -LiteralPath $script:Download
        { Publish-YurunaBaseImage -DownloadFile $script:Download -BaseImageFile $script:BaseFile -PreviousFile $script:Previous -ExpectedSize 9 -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText($script:BaseFile) | Should -Be 'old bytes'
    }
    It 'refuses a published image that does not hold the downloaded size and puts the previous one back' {
        { Publish-YurunaBaseImage -DownloadFile $script:Download -BaseImageFile $script:BaseFile -PreviousFile $script:Previous -ExpectedSize 4096 -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText($script:BaseFile) | Should -Be 'old bytes'
    }
    It 'leaves no base image behind when a first publish has the wrong size' {
        Remove-Item -LiteralPath $script:BaseFile
        { Publish-YurunaBaseImage -DownloadFile $script:Download -BaseImageFile $script:BaseFile -PreviousFile $script:Previous -ExpectedSize 4096 -Confirm:$false } | Should -Throw
        Test-Path -LiteralPath $script:BaseFile | Should -BeFalse -Because 'an image that exists is all the Windows skip guard asks for'
    }
    It 'leaves the images alone while another process publishes the same one' {
        $start = Get-YurunaProcessStartUtc -ProcessId $PID
        [IO.File]::WriteAllText("$($script:BaseFile).publish.lock", (ConvertTo-Json -Compress -InputObject ([ordered]@{ pid = $PID; startTicks = $start.Ticks })))
        { Publish-YurunaBaseImage -DownloadFile $script:Download -BaseImageFile $script:BaseFile -PreviousFile $script:Previous -ExpectedSize 9 -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText($script:BaseFile) | Should -Be 'old bytes'
        Test-Path -LiteralPath $script:Download | Should -BeTrue
    }
}

Describe 'Snapshot probes can say they do not know' {
    BeforeAll {
        function Invoke-LiftedProbe {
            param([string]$Driver, [string[]]$Name, [scriptblock]$Stubs, [scriptblock]$Call)
            $source = ($Name | ForEach-Object { Get-SourceFunction -Path "host/$Driver/modules/Yuruna.Host.psm1" -Name $_ }) -join "`n"
            # A module-qualified cmdlet cannot be shadowed; the lifted copy calls
            # the stub by its bare name instead.
            $source = $source.Replace('Hyper-V\Get-VMCheckpoint', 'Get-VMCheckpoint')
            return (& { . $Stubs; . ([scriptblock]::Create($source)); & $Call })
        }
    }
    It 'KVM reads the snapshot list, whatever language libvirt answers in' {
        $stubs = { function Get-VMState { 'stopped' }; function Invoke-Virsh { param($VirshArgs) $null = $VirshArgs; $global:LASTEXITCODE = $script:VirshExit; $script:VirshLines } }
        $script:VirshExit = 0; $script:VirshLines = @('base', 'ubuntu.server.24.base', '')
        Invoke-LiftedProbe -Driver ubuntu.kvm -Name 'Get-VMDiskSnapshotState' -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'ubuntu.server.24.base' } | Should -Be 'present'
        Invoke-LiftedProbe -Driver ubuntu.kvm -Name 'Get-VMDiskSnapshotState' -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'other' } | Should -Be 'absent'
        $script:VirshExit = 1; $script:VirshLines = @('error: failed to connect to the hypervisor')
        Invoke-LiftedProbe -Driver ubuntu.kvm -Name 'Get-VMDiskSnapshotState' -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'base' } | Should -Be 'unknown'
    }
    It 'Hyper-V lists the checkpoints and reads a failed listing as unknown' {
        $stubs = {
            function Get-VMState { 'stopped' }
            function Get-VMCheckpoint { param($VMName, $ErrorAction) $null = $VMName, $ErrorAction; if ($script:CheckpointThrows) { throw 'WMI did not answer' }; $script:Checkpoints }
            # The listing runs in the driver's bounded call; here it runs in place.
            function Invoke-HyperVLifecycleCmdlet { param($Verb, $VMName, $ScriptBlock, $ArgumentList) $null = $Verb, $VMName; & $ScriptBlock @ArgumentList }
        }
        $script:CheckpointThrows = $false; $script:Checkpoints = @([pscustomobject]@{ Name = 'base' })
        Invoke-LiftedProbe -Driver windows.hyper-v -Name 'Get-VMDiskSnapshotState' -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'base' } | Should -Be 'present'
        $script:Checkpoints = @()
        Invoke-LiftedProbe -Driver windows.hyper-v -Name 'Get-VMDiskSnapshotState' -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'base' } | Should -Be 'absent'
        $script:CheckpointThrows = $true
        Invoke-LiftedProbe -Driver windows.hyper-v -Name 'Get-VMDiskSnapshotState' -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'base' } | Should -Be 'unknown'
    }
    It 'UTM tells a missing bundle from a host that cannot look, and an unread disk from a bare one' {
        $stubs = {
            function Get-UtmBundleDisk { param($VMName) $null = $VMName; @{ Ready = -not $script:BundleReason; Reason = $script:BundleReason; Disk = @([pscustomobject]@{ FullName = '/b/Data/disk.qcow2' }) } }
            function Invoke-UtmHostTool { param($Tool, $ArgumentList, $TimeoutSeconds) $null = $Tool, $ArgumentList, $TimeoutSeconds; @{ ExitCode = $script:QemuExit; StdOut = $script:QemuOut } }
            function Test-BoundedNativeResultComplete { param($Result) $null = $Result; $true }
        }
        $names = @('Get-VMDiskSnapshotState', 'Get-UtmDiskSnapshotState')
        $script:BundleReason = ''; $script:QemuExit = 0; $script:QemuOut = "Snapshot list:`nID TAG VM SIZE DATE`n1 base 0 B 2026-10-01"
        Invoke-LiftedProbe -Driver macos.utm -Name $names -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'base' } | Should -Be 'present'
        Invoke-LiftedProbe -Driver macos.utm -Name $names -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'other' } | Should -Be 'absent'
        $script:QemuExit = 1
        Invoke-LiftedProbe -Driver macos.utm -Name $names -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'base' } | Should -Be 'unknown'
        $script:BundleReason = 'missing-directory'
        Invoke-LiftedProbe -Driver macos.utm -Name $names -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'base' } | Should -Be 'absent'
        $script:BundleReason = 'missing-tool'
        Invoke-LiftedProbe -Driver macos.utm -Name $names -Stubs $stubs -Call { Get-VMDiskSnapshotState -VMName vm -Id 'base' } | Should -Be 'unknown'
    }
    It 'Test-VMDiskSnapshot throws for an unknown answer on every host, so a caller''s indeterminate branch runs' -TestCases @(
        @{ Driver = 'ubuntu.kvm' }, @{ Driver = 'windows.hyper-v' }, @{ Driver = 'macos.utm' }) {
        param($Driver)
        $stubs = { function Get-VMDiskSnapshotState { param($VMName, $Id) $null = $VMName, $Id; $script:ProbeAnswer } }
        $script:ProbeAnswer = 'unknown'
        { Invoke-LiftedProbe -Driver $Driver -Name 'Test-VMDiskSnapshot' -Stubs $stubs -Call { Test-VMDiskSnapshot -VMName vm -Id 'base' } } | Should -Throw
        $script:ProbeAnswer = 'absent'
        Invoke-LiftedProbe -Driver $Driver -Name 'Test-VMDiskSnapshot' -Stubs $stubs -Call { Test-VMDiskSnapshot -VMName vm -Id 'base' } | Should -BeFalse
        $script:ProbeAnswer = 'present'
        Invoke-LiftedProbe -Driver $Driver -Name 'Test-VMDiskSnapshot' -Stubs $stubs -Call { Test-VMDiskSnapshot -VMName vm -Id 'base' } | Should -BeTrue
    }
}

Describe 'A host stage names the class of its failure' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.Image.psm1') -Force -DisableNameChecking
        $script:ProvisionModule = Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1'
        function New-NewVmFixture {
            param([string]$Body)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $folder = Join-Path $root 'host/fixture/guest.fixture'
            $null = New-Item -ItemType Directory -Path $folder -Force
            Set-Content -LiteralPath (Join-Path $folder 'New-VM.ps1') -Value "param([string]`$VMName)`n$Body"
            return $root
        }
    }
    BeforeEach {
        $script:priorLogDir = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $env:YURUNA_LOG_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:priorLogDir }

    It 'files a New-VM failure under the class its builder recorded' {
        $root = New-NewVmFixture -Body "Import-Module '$($script:ProvisionModule)' -DisableNameChecking; Write-YurunaProvisionResult -Kind unresponsive -Message 'virt-install gave no answer'; exit 1"
        $r = Invoke-PerGuestNewVm -HostSubdir 'host/fixture' -GuestKey 'guest.fixture' -RepoRoot $root -VMName 'test-01' -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        $r.failureClass | Should -Be 'hypervisor_unresponsive'
        $r.kind | Should -Be 'unresponsive'
        $r.errorMessage | Should -Match 'virt-install gave no answer'
        $env:YURUNA_PROVISION_RESULT | Should -BeNullOrEmpty -Because 'the path is named for the stage only'
    }
    It 'leaves the class to the caller for a builder that recorded nothing, even with a record left from an earlier run' {
        $stale = Get-YurunaProvisionResultPath -GuestKey 'guest.fixture' -Stage 'NewVM'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $stale) -Force
        Set-Content -LiteralPath $stale -Value '{"kind":"integrity","message":"old"}'
        $root = New-NewVmFixture -Body 'exit 1'
        $r = Invoke-PerGuestNewVm -HostSubdir 'host/fixture' -GuestKey 'guest.fixture' -RepoRoot $root -VMName 'test-01' -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        $r.ContainsKey('failureClass') | Should -BeFalse -Because 'the runner keeps provisioning_failure for a builder that said nothing'
    }
    It 'records why an image download stopped: <Case>' -ForEach @(
        @{ Case = 'the transfer failed'; Fetch = 'throw'; Policy = 'WarnAndDelete'; Kind = 'network' }
        @{ Case = 'the bytes failed their checksum'; Fetch = 'write'; Policy = 'WarnAndDelete'; Kind = 'integrity' }
        @{ Case = 'a mismatch the caller accepts'; Fetch = 'write'; Policy = 'WarnAndContinue'; Kind = '' }
    ) {
        $record = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
        $dest = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).img"
        $prior = Save-YurunaTestEnvironment -Name 'YURUNA_PROVISION_RESULT'
        $env:YURUNA_PROVISION_RESULT = $record
        $body = if ($Fetch -eq 'throw') { "throw 'The response ended prematurely.'" } else { "[IO.File]::WriteAllText(`$OutFile, 'served bytes')" }
        $null = New-Item -Path Function:global:Save-CachedHttpUri -Value ([scriptblock]::Create("param(`$Uri, `$OutFile) `$null = `$Uri; $body")) -Force
        try {
            $null = Save-ImageWithChecksum -SourceUrl 'https://images.example.invalid/disk.img' -DestPath $dest `
                -ExpectedSha256 ('0' * 64) -OnMismatch $Policy -RetryBudgetSeconds 0 -Confirm:$false -WarningAction SilentlyContinue 6>$null
            $result = Read-YurunaProvisionResult -Path $record
            if ($Kind) { $result.kind | Should -Be $Kind } else { $result | Should -BeNullOrEmpty }
        } finally {
            Restore-YurunaTestEnvironment -Saved $prior
            Remove-Item -LiteralPath Function:global:Save-CachedHttpUri -ErrorAction SilentlyContinue
        }
    }
    It 'records a Get-Image that cannot run on this architecture as a plan the host cannot run: <Script>' -Skip:(-not $IsLinux) -ForEach @(
        @{ Script = 'host/ubuntu.kvm/guest.amazon.linux.2023/Get-Image.ps1'; Arch = 'riscv64' }
        @{ Script = 'host/ubuntu.kvm/guest.windows.11/Get-Image.ps1'; Arch = 'aarch64' }
        @{ Script = 'host/ubuntu.kvm/guest.stash-service/Get-Image.ps1'; Arch = 'riscv64' }
    ) {
        $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $bin
        $uname = Join-Path $bin 'uname'
        [IO.File]::WriteAllText($uname, "#!/bin/sh`necho $Arch`n")
        & chmod +x $uname
        $record = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
        $prior = Save-YurunaTestEnvironment -Name 'PATH', 'YURUNA_PROVISION_RESULT'
        try {
            $env:PATH = "$bin$([IO.Path]::PathSeparator)$($prior.PATH)"
            $env:YURUNA_PROVISION_RESULT = $record
            $null = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot $Script) 2>&1
            $LASTEXITCODE | Should -Be 1
        } finally {
            Restore-YurunaTestEnvironment -Saved $prior
        }
        $result = Read-YurunaProvisionResult -Path $record
        $result.kind | Should -Be 'unsupported'
        $result.failureClass | Should -Be 'plan_invalid' -Because 'a retry on the same host cannot change its architecture'
    }
    It 'files a Start-VM failure under the class the driver names' {
        $source = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/modules/Test.RunnerInnerLoop.psm1')
        $start = $source.IndexOf('# --- REGION: Start-VM', [StringComparison]::Ordinal)
        $end = $source.IndexOf('# --- REGION: Start-GuestOS', $start, [StringComparison]::Ordinal)
        $block = $source.Substring($start, $end - $start)
        $block | Should -Match ([regex]::Escape("`$r['failureClass']"))
        $block | Should -Match "Complete-GuestStepFailure [^\r\n]*-StepName 'Start-VM' [^\r\n]*-FailureClass \`$startVmClass"
    }
}

Describe 'Hypervisor calls on contract paths are bounded' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
        function Invoke-LiftedDriver {
            param([string]$Driver, [string[]]$Name, [scriptblock]$Stubs, [scriptblock]$Call)
            $source = ($Name | ForEach-Object { Get-SourceFunction -Path "host/$Driver/modules/Yuruna.Host.psm1" -Name $_ }) -join "`n"
            return (& { . $Stubs; . ([scriptblock]::Create($source)); & $Call })
        }
    }
    It 'KVM ends a virsh call that does not answer, and tells it from a refusal' -Skip:(-not $IsLinux) {
        $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $bin
        $virsh = Join-Path $bin 'virsh'
        [IO.File]::WriteAllText($virsh, "#!/bin/sh`ncase `"`$*`" in *slow*) sleep 30;; *) echo 'error: refused' >&2; exit 1;; esac`n")
        & chmod +x $virsh
        $prior = Save-YurunaTestEnvironment -Name 'PATH'
        try {
            $env:PATH = "$bin$([IO.Path]::PathSeparator)$($prior.PATH)"
            $names = 'Invoke-Virsh', 'Invoke-VirshBounded', 'Test-DriverNativeResultComplete', 'Test-VirshLastCallUnanswered'
            $stubs = { $script:VirshUri = 'qemu:///system'; $script:VirshCallTimeoutSeconds = 120; $script:VirshLastCallUnanswered = $false }
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $slow = Invoke-LiftedDriver -Driver ubuntu.kvm -Name $names -Stubs $stubs -Call {
                $null = Invoke-Virsh -VirshArgs @('slow') -TimeoutSeconds 2
                @{ Exit = $LASTEXITCODE; Unanswered = (Test-VirshLastCallUnanswered) }
            }
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
            $slow.Exit | Should -Be 124
            $slow.Unanswered | Should -BeTrue
            $refused = Invoke-LiftedDriver -Driver ubuntu.kvm -Name $names -Stubs $stubs -Call {
                $lines = Invoke-Virsh -VirshArgs @('start', 'vm')
                @{ Exit = $LASTEXITCODE; Unanswered = (Test-VirshLastCallUnanswered); Lines = $lines }
            }
            $refused.Exit | Should -Be 1
            $refused.Unanswered | Should -BeFalse
            $refused.Lines | Should -Contain 'error: refused'
        } finally { Restore-YurunaTestEnvironment -Saved $prior }
    }
    It 'KVM Start-VM files a start libvirt never answered as hypervisor_unresponsive, and a refusal as provisioning_failure' {
        $stubs = {
            function Get-VirshDomState { param($VMName) $null = $VMName; 'shut off' }
            function Start-VMDhcpCapture { param($VMName) $null = $VMName }
            function Invoke-Virsh { param($VirshArgs) $null = $VirshArgs; $script:VirshLastCallUnanswered = $script:FixtureUnanswered; $global:LASTEXITCODE = $script:FixtureExit; @('error: fixture') }
        }
        $names = 'Start-VM', 'New-KvmVerbFailure', 'Test-VirshLastCallUnanswered'
        $script:FixtureUnanswered = $true; $script:FixtureExit = 124
        (Invoke-LiftedDriver -Driver ubuntu.kvm -Name $names -Stubs $stubs -Call { Start-VM -VMName vm -Confirm:$false }).failureClass | Should -Be 'hypervisor_unresponsive'
        $script:FixtureUnanswered = $false; $script:FixtureExit = 1
        (Invoke-LiftedDriver -Driver ubuntu.kvm -Name $names -Stubs $stubs -Call { Start-VM -VMName vm -Confirm:$false }).failureClass | Should -Be 'provisioning_failure'
    }
    It 'UTM Start-VM files a control channel that stopped acting as hypervisor_unresponsive' {
        $stubs = {
            function Test-Path { param($Path) [string]$Path -like '*.utm' }
            function Get-VMStateRecord { param($VMName) $null = $VMName; @{ State = 'stopped' } }
            function Get-VncDisplayForVm { param($VMName) $null = $VMName; 1 }
            function Get-ClaimedVncDisplay { param($ExcludeVMName) $null = $ExcludeVMName; @() }
            function Find-FreeVncDisplay { param($Preferred, $ExcludeDisplays) $null = $ExcludeDisplays; $Preferred }
            function Get-VncDisplayFromBundle { param($VMName) $null = $VMName; 1 }
            function Start-UtmDialogWatchdog { }
            function Start-UtmDetachedLaunch { param($Tool, $ArgumentList) $null = $Tool, $ArgumentList }
            function Save-UtmControlSnapshot { param($Trigger, $VMName) $null = $Trigger, $VMName }
            function Invoke-UtmVMStartWithRetry { param($VMName) $null = $VMName; @{ success = $false; errorMessage = 'no answer'; kind = 'apple-event'; controlHung = $script:FixtureHung; appleEventReason = 'timeout' } }
        }
        $script:FixtureHung = $true
        (Invoke-LiftedDriver -Driver macos.utm -Name 'Start-UtmVM' -Stubs $stubs -Call { Start-UtmVM -VMName vm -Confirm:$false }).failureClass | Should -Be 'hypervisor_unresponsive'
        $script:FixtureHung = $false
        (Invoke-LiftedDriver -Driver macos.utm -Name 'Start-UtmVM' -Stubs $stubs -Call { Start-UtmVM -VMName vm -Confirm:$false }).failureClass | Should -Be 'provisioning_failure'
    }
    It 'Hyper-V runs a lifecycle cmdlet under a cap and keeps its own error record' {
        $names = 'Invoke-HyperVBoundedCall', 'Invoke-HyperVLifecycleCmdlet'
        $stubs = { $script:HyperVLifecycleTimeoutSeconds = 2 }
        $answer = Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
            Invoke-HyperVBoundedCall -ArgumentList @('vm') -ScriptBlock { param($Name) "started $Name" }
        }
        $answer.TimedOut | Should -BeFalse
        $answer.Output | Should -Be 'started vm'
        $failed = Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
            Invoke-HyperVBoundedCall -ScriptBlock { throw [System.InvalidOperationException]::new('insufficient memory') }
        }
        $failed.Error | Should -BeOfType [System.Management.Automation.ErrorRecord]
        $failed.Error.Exception | Should -BeOfType [System.InvalidOperationException] -Because 'the caller classifies the refusal from the record itself'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $hung = Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
            Invoke-HyperVBoundedCall -TimeoutSeconds 1 -ScriptBlock { Start-Sleep -Seconds 30 }
        }
        $hung.TimedOut | Should -BeTrue
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 15
        { Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
                Invoke-HyperVLifecycleCmdlet -Verb 'Rename-VM' -VMName vm -ScriptBlock { Start-Sleep -Seconds 30 } } } |
            Should -Throw -ExpectedMessage 'host.hyperv_lifecycle_unanswered'
    }
    It 'Hyper-V reports a bounded call whose job ends without an answer as an error' {
        # The job body always emits one answer object; a job that returns none
        # never ran its body to the end, which is not a call that found nothing.
        $names = 'Invoke-HyperVBoundedCall', 'Invoke-HyperVLifecycleCmdlet'
        $stubs = { $script:HyperVLifecycleTimeoutSeconds = 2; function Receive-Job { param($Job) $null = $Job } }
        $silent = Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
            Invoke-HyperVBoundedCall -ArgumentList @('vm') -ScriptBlock { param($Name) "listed $Name" }
        }
        $silent.TimedOut | Should -BeFalse
        $silent.Error | Should -BeOfType [System.Management.Automation.ErrorRecord]
        $silent.Error.Exception.Message | Should -Be 'host.hyperv_bounded_call_no_answer'
        @($silent.Output).Count | Should -Be 0
        { Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
                Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMCheckpoint' -VMName vm -ScriptBlock { 'listed' } } } |
            Should -Throw -ExpectedMessage 'host.hyperv_bounded_call_no_answer'
    }
    It 'Hyper-V bounds a test-guest builder''s cmdlet and records the New-VM stage''s kind' {
        # The call runs in a thread job that loads modules by name, so the stand-in
        # Hyper-V module sits on the module path rather than in this session.
        $modules = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $modules 'Hyper-V')
        [IO.File]::WriteAllText((Join-Path $modules 'Hyper-V/Hyper-V.psm1'), @'
function Get-VM { param([string]$Name) if ($Name -eq 'absent') { throw [System.InvalidOperationException]::new("no VM named $Name") }; [pscustomobject]@{ Name = $Name } }
function Set-VMMemory { param([string]$VMName, [bool]$DynamicMemoryEnabled) throw [System.InvalidOperationException]::new('memory refused') }
function Start-VM { param([string]$Name) Start-Sleep -Seconds 30 }
'@)
        $recorded = [Collections.Generic.List[string]]::new()
        # The wrapper asks the exhaustion classifier about every refusal, so it
        # is lifted with the wrapper; none of these refusals is one.
        $names = 'Invoke-HyperVBoundedCall', 'Invoke-HyperVGuestBuildCmdlet', 'Test-HostResourceExhaustionError'
        $stubs = {
            $script:HyperVLifecycleTimeoutSeconds = 2
            function Write-YurunaProvisionResult { param($Kind, $Message) $recorded.Add("$Kind") }
        }
        $prior = Save-YurunaTestEnvironment -Name 'PSModulePath'
        try {
            $env:PSModulePath = "$modules$([IO.Path]::PathSeparator)$($prior.PSModulePath)"
            $vm = Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
                Invoke-HyperVGuestBuildCmdlet -VMName vm -Command 'Hyper-V\Get-VM' -Parameter @{ Name = 'vm' }
            }
            $vm.Name | Should -Be 'vm'
            @($recorded) | Should -BeNullOrEmpty -Because 'an answered call records nothing'
            $absent = Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
                Invoke-HyperVGuestBuildCmdlet -VMName vm -Command 'Hyper-V\Get-VM' -Parameter @{ Name = 'absent' } -Optional
            }
            $absent | Should -BeNullOrEmpty
            @($recorded) | Should -BeNullOrEmpty -Because 'an optional lookup''s refusal is its answer'
            { Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
                    Invoke-HyperVGuestBuildCmdlet -VMName vm -Command 'Hyper-V\Set-VMMemory' -Parameter @{ VMName = 'vm'; DynamicMemoryEnabled = $false } } } |
                Should -Throw -ExpectedMessage 'memory refused'
            @($recorded) | Should -Be @('tool')
            $clock = [Diagnostics.Stopwatch]::StartNew()
            { Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
                    Invoke-HyperVGuestBuildCmdlet -VMName vm -Command 'Hyper-V\Start-VM' -Parameter @{ Name = 'vm' } } } |
                Should -Throw -ExpectedMessage 'host.hyperv_lifecycle_unanswered'
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
            @($recorded) | Should -Be @('tool', 'unresponsive')
        } finally { Restore-YurunaTestEnvironment -Saved $prior }
    }
    It 'Hyper-V names the commit position beside a start the host refused for want of system resources' {
        # The refusal names the guest's size and nothing about the host, and the
        # physical figure a reader reaches for next is the wrong one: the start
        # was charged against the commit limit, which a leaking parent partition
        # exhausts with gigabytes of physical memory still free.
        $modules = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $modules 'Hyper-V')
        [IO.File]::WriteAllText((Join-Path $modules 'Hyper-V/Hyper-V.psm1'), @'
function Start-VM { param([string]$Name) throw [System.InvalidOperationException]::new("'$Name' failed to start. Unable to allocate 12288 MB of RAM: Insufficient system resources exist to complete the requested service. (0x800705AA).") }
function Set-VMMemory { param([string]$VMName, [bool]$DynamicMemoryEnabled) throw [System.InvalidOperationException]::new('memory refused') }
'@)
        $recorded = [Collections.Generic.List[string]]::new()
        $names = 'Invoke-HyperVBoundedCall', 'Invoke-HyperVGuestBuildCmdlet', 'Test-HostResourceExhaustionError', 'Format-HostMemoryStatus'
        $stubs = {
            $script:HyperVLifecycleTimeoutSeconds = 5
            function Write-YurunaProvisionResult { param($Kind, $Message) $recorded.Add("${Kind}: $Message") }
            function Get-HostMemoryStatus { return @{ availableMb = 19661; committedBytes = 38440000000; commitLimitBytes = 48210000000; commitAvailableBytes = 9770000000; source = 'fixture' } }
        }
        $prior = Save-YurunaTestEnvironment -Name 'PSModulePath'
        try {
            $env:PSModulePath = "$modules$([IO.Path]::PathSeparator)$($prior.PSModulePath)"
            { Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
                    Invoke-HyperVGuestBuildCmdlet -VMName vm -Command 'Hyper-V\Start-VM' -Parameter @{ Name = 'vm' } } } |
                Should -Throw -ExpectedMessage '*0x800705AA*'
            { Invoke-LiftedDriver -Driver windows.hyper-v -Name $names -Stubs $stubs -Call {
                    Invoke-HyperVGuestBuildCmdlet -VMName vm -Command 'Hyper-V\Set-VMMemory' -Parameter @{ VMName = 'vm'; DynamicMemoryEnabled = $false } } } |
                Should -Throw -ExpectedMessage 'memory refused'
            @($recorded).Count | Should -Be 2
            $recorded[0] | Should -Match '^tool: Hyper-V\\Start-VM: .*0x800705AA.*; commit 35\.8 of 44\.9 GB charged, 9\.1 GB uncharged; 19\.2 GB physical available$'
            $recorded[1] | Should -Be 'tool: Hyper-V\Set-VMMemory: memory refused' -Because 'only a refusal for want of resources earns the memory position'
        } finally { Restore-YurunaTestEnvironment -Saved $prior }
    }
    It 'calls no hypervisor tool outside its bounded wrapper on <Driver>' -ForEach @(
        @{ Driver = 'ubuntu.kvm'; Files = @('host/ubuntu.kvm/modules/Yuruna.Host.psm1', 'host/ubuntu.kvm/modules/New-UbuntuServerVM.ps1',
                'host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1', 'host/ubuntu.kvm/guest.windows.11/New-VM.ps1',
                'host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1', 'host/ubuntu.kvm/guest.ubuntu.server.26/New-VM.ps1')
            Raw = @('virsh', 'virt-install'); Wrapper = @() }
        @{ Driver = 'windows.hyper-v'; Files = @('host/windows.hyper-v/modules/Yuruna.Host.psm1')
            Raw = @('Hyper-V\Start-VM', 'Hyper-V\Stop-VM', 'Hyper-V\Remove-VM', 'Hyper-V\Rename-VM', 'Hyper-V\Move-VMStorage',
                'Hyper-V\Checkpoint-VM', 'Hyper-V\Restore-VMCheckpoint', 'Hyper-V\Remove-VMCheckpoint', 'Hyper-V\Get-VMCheckpoint')
            Wrapper = @('Invoke-HyperVBoundedCall', 'Invoke-HyperVLifecycleCmdlet', 'Start-Job') }
        @{ Driver = 'macos.utm'; Files = @('host/macos.utm/modules/Yuruna.Host.psm1'); Raw = @('utmctl', 'osascript'); Wrapper = @() }
        # The test-guest builders run as their own process: every Hyper-V cmdlet
        # they call goes through Invoke-HyperVGuestBuildCmdlet, which names it as data.
        @{ Driver = 'windows.hyper-v test-guest builders'; Files = @('host/windows.hyper-v/modules/New-UbuntuServerVM.ps1',
                'host/windows.hyper-v/guest.amazon.linux.2023/New-VM.ps1', 'host/windows.hyper-v/guest.windows.11/New-VM.ps1',
                'host/windows.hyper-v/guest.ubuntu.server.24/New-VM.ps1', 'host/windows.hyper-v/guest.ubuntu.server.26/New-VM.ps1')
            Raw = @(); RawPattern = '^(Hyper-V\\[A-Za-z]+-[A-Za-z]+|(Get|Set|Add|New|Enable|Disable|Remove|Start|Stop|Resize|Convert|Mount|Dismount)-(VM|VHD)[A-Za-z]*)$'
            Wrapper = @() }
    ) {
        # A driver root stands for every file of the driver, each scanned on its own
        # so a finding names the file and line it is on.
        $scanned = foreach ($file in $Files) {
            $driver = Resolve-YurunaDriverPath -Path (Join-Path $script:RepoRoot $file)
            if ($driver) { Get-YurunaDriverFile -Driver $driver.Driver | ForEach-Object { [IO.Path]::GetRelativePath($script:RepoRoot, $_).Replace('\', '/') } } else { $file }
        }
        $raw = foreach ($file in $scanned) {
            $path = Join-Path $script:RepoRoot $file
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = [string]$command.CommandElements[0].Extent.Text.Trim("'", '"')
                if ($Raw -notcontains $name -and -not ($RawPattern -and $name -match $RawPattern)) { continue }
                $wrapped = $false
                for ($parent = $command.Parent; $parent; $parent = $parent.Parent) {
                    if ($parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                        $parent.Parent -is [System.Management.Automation.Language.CommandParameterAst] -or
                        $parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                        $parent.Parent -is [System.Management.Automation.Language.CommandAst]) {
                        $owner = if ($parent.Parent -is [System.Management.Automation.Language.CommandAst]) { $parent.Parent } else { $parent.Parent.Parent }
                        if ($owner -is [System.Management.Automation.Language.CommandAst] -and $Wrapper -contains $owner.GetCommandName()) { $wrapped = $true; break }
                    }
                }
                if (-not $wrapped) { "${file}:$($command.Extent.StartLineNumber) $name" }
            }
        }
        @($raw) | Should -BeNullOrEmpty -Because 'a hypervisor that stops answering must become a classified fault inside a deadline, not a watchdog kill'
    }
}

Describe 'A disk snapshot save replaces the earlier one only once the new one is verified' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
        function New-FakeHypervisor {
            param([hashtable]$Vm, [string[]]$FailOn = @())
            $hv = [pscustomobject]@{ Vm = $Vm; Log = [System.Collections.Generic.List[string]]::new(); FailOn = $FailOn }
            $primitive = @{
                State         = { param($Name) if ($hv.FailOn -contains "state:$Name") { 'unknown' } elseif ($hv.Vm.ContainsKey($Name)) { 'stopped' } else { 'absent' } }.GetNewClosure()
                SnapshotState = { param($Name, $Id) if (-not $hv.Vm.ContainsKey($Name)) { 'absent' } elseif ($hv.Vm[$Name] -contains $Id) { 'present' } else { 'absent' } }.GetNewClosure()
                Stop          = { param($Name) $hv.Log.Add("stop $Name"); $hv.Vm.ContainsKey($Name) -and $hv.FailOn -notcontains "stop:$Name" }.GetNewClosure()
                Rename        = { param($Name, $NewName)
                    $hv.Log.Add("rename $Name $NewName")
                    if ($hv.FailOn -contains "rename:$Name" -or -not $hv.Vm.ContainsKey($Name) -or $hv.Vm.ContainsKey($NewName)) { return $false }
                    $hv.Vm[$NewName] = $hv.Vm[$Name]; $hv.Vm.Remove($Name); return $true }.GetNewClosure()
                Remove        = { param($Name) $hv.Log.Add("remove $Name"); if ($hv.FailOn -contains "remove:$Name") { return $false }; $hv.Vm.Remove($Name); $true }.GetNewClosure()
                Snapshot      = { param($Name, $Id)
                    $hv.Log.Add("snapshot $Name $Id")
                    if ($hv.FailOn -contains "snapshot:$Name") { return $false }
                    $hv.Vm[$Name] = @(@($hv.Vm[$Name]) | Where-Object { $_ -ne $Id }) + $Id; $true }.GetNewClosure()
            }
            return [pscustomobject]@{ Hv = $hv; Primitive = $primitive }
        }
    }
    It 'snapshots the working VM under its final name' {
        $f = New-FakeHypervisor -Vm @{ 'test-01' = @() }
        Invoke-YurunaDiskSnapshotSave -VMName 'test-01' -Id 'base' -Primitive $f.Primitive -Confirm:$false | Should -BeTrue
        ($f.Hv.Log -join '|') | Should -Be 'stop test-01|rename test-01 base|snapshot base base' -Because 'a KVM snapshot freezes the name it was taken under'
        $f.Hv.Vm.Keys | Should -Be @('base')
    }
    It 'replaces a stranded persisted VM instead of failing on its name, removing it only after the new snapshot is verified' {
        $f = New-FakeHypervisor -Vm @{ 'test-01' = @(); 'base' = @() }
        Invoke-YurunaDiskSnapshotSave -VMName 'test-01' -Id 'base' -Primitive $f.Primitive -Confirm:$false | Should -BeTrue
        ($f.Hv.Log -join '|') | Should -Be 'stop test-01|rename base base.previous|rename test-01 base|snapshot base base|remove base.previous'
        @($f.Hv.Vm.Keys) | Should -Be @('base')
        $f.Hv.Vm['base'] | Should -Contain 'base'
    }
    It 'keeps the earlier persisted VM, its name and its snapshot when <Case>' -ForEach @(
        @{ Case = 'the snapshot fails'; FailOn = @('snapshot:base') }
        @{ Case = 'the working VM cannot take the name'; FailOn = @('rename:test-01') }
    ) {
        $f = New-FakeHypervisor -Vm @{ 'test-01' = @(); 'base' = @('base') } -FailOn $FailOn
        Invoke-YurunaDiskSnapshotSave -VMName 'test-01' -Id 'base' -Primitive $f.Primitive -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        $f.Hv.Vm['base'] | Should -Be @('base') -Because 'the verified snapshot survives a failed replacement'
        $f.Hv.Vm.ContainsKey('test-01') | Should -BeTrue -Because 'the working VM keeps its name'
        $f.Hv.Vm.ContainsKey('base.previous') | Should -BeFalse
        @($f.Hv.Log | Where-Object { $_ -like 'remove*' }) | Should -BeNullOrEmpty
    }
    It 'settles an interrupted save whose new snapshot was verified by removing the aside' {
        $f = New-FakeHypervisor -Vm @{ 'test-02' = @(); 'base' = @('base'); 'base.previous' = @('base') }
        Invoke-YurunaDiskSnapshotSave -VMName 'test-02' -Id 'base' -Primitive $f.Primitive -Confirm:$false | Should -BeTrue
        $f.Hv.Log[0] | Should -Be 'remove base.previous'
        @($f.Hv.Vm.Keys) | Should -Be @('base')
    }
    It 'settles an interrupted save whose new snapshot was never verified by restoring the aside' {
        $f = New-FakeHypervisor -Vm @{ 'test-02' = @(); 'base' = @(); 'base.previous' = @('base') } -FailOn @('snapshot:base')
        Invoke-YurunaDiskSnapshotSave -VMName 'test-02' -Id 'base' -Primitive $f.Primitive -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        ($f.Hv.Log[0..1] -join '|') | Should -Be 'remove base|rename base.previous base'
        $f.Hv.Vm['base'] | Should -Be @('base') -Because 'the verified snapshot from before the interruption is back under its name'
    }
    It 'changes nothing when it cannot tell whether <Name> exists' -ForEach @(@{ Name = 'base' }, @{ Name = 'base.previous' }) {
        $f = New-FakeHypervisor -Vm @{ 'test-01' = @(); 'base' = @('base'); 'base.previous' = @('base') } -FailOn @("state:$Name")
        Invoke-YurunaDiskSnapshotSave -VMName 'test-01' -Id 'base' -Primitive $f.Primitive -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        @($f.Hv.Log | Where-Object { $_ -like 'remove*' -or $_ -like 'rename*' }) | Should -BeNullOrEmpty
    }
    It 'snapshots a working VM already named for the snapshot in place' {
        $f = New-FakeHypervisor -Vm @{ 'base' = @('base') }
        Invoke-YurunaDiskSnapshotSave -VMName 'base' -Id 'base' -Primitive $f.Primitive -Confirm:$false | Should -BeTrue
        ($f.Hv.Log -join '|') | Should -Be 'stop base|snapshot base base'
    }
    It 'runs the same save on <Driver>, which hands it all six primitives' -ForEach @(
        @{ Driver = 'ubuntu.kvm' }, @{ Driver = 'windows.hyper-v' }, @{ Driver = 'macos.utm' }) {
        $ast = Get-YurunaDriverAst -Driver $Driver
        $save = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-VMDiskSnapshot' }, $true)
        $call = $save.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-YurunaDiskSnapshotSave' }, $true)
        $call | Should -Not -BeNullOrEmpty
        $table = $call.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)
        @($table.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text } | Sort-Object) | Should -Be @('Remove', 'Rename', 'Snapshot', 'SnapshotState', 'State', 'Stop')
    }
}

Describe 'Each owner adds and removes only its own host port forwards' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
        function New-PortMapLedger {
            param([hashtable]$Owner)
            $path = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
            foreach ($name in $Owner.Keys) {
                $rows = @($Owner[$name] | ForEach-Object { [pscustomobject]@{ HostPort = $_; VMPort = $_; ProxyProtocol = $false } })
                Set-YurunaPortMapOwner -Path $path -Owner $name -VMIp '192.0.2.20' -Mapping $rows -Confirm:$false | Should -BeTrue
            }
            return $path
        }
    }
    It 'records each owner beside the others, and drops an owner that holds nothing' {
        $path = New-PortMapLedger -Owner @{ 'stash-service' = @(2222); 'caching-proxy-service' = @(3128, 80) }
        $owners = Read-YurunaPortMapLedger -Path $path
        @($owners.Keys | Sort-Object) | Should -Be @('caching-proxy-service', 'stash-service')
        @($owners['caching-proxy-service'].mappings.hostPort) | Should -Be @(3128, 80)
        Set-YurunaPortMapOwner -Path $path -Owner 'caching-proxy-service' -Confirm:$false | Should -BeTrue
        @((Read-YurunaPortMapLedger -Path $path).Keys) | Should -Be @('stash-service')
        Test-Path -LiteralPath "$path.lock" | Should -BeFalse -Because 'the lock is released'
    }
    It 'reads a record written before owners were recorded as holding no owners' {
        $path = Join-Path $TestDrive 'legacy-port-map.json'
        Set-Content -LiteralPath $path -Value '{"vmIp":"192.0.2.20","ports":[80,3128],"mappings":[{"hostPort":80,"vmPort":80}]}'
        (Read-YurunaPortMapLedger -Path $path).Count | Should -Be 0
    }
    It 'releases the owner''s own ports, refuses another owner''s, and replaces an unrecorded forward only where it installs' {
        $owners = Read-YurunaPortMapLedger -Path (New-PortMapLedger -Owner @{ 'stash-service' = @(2222); 'caching-proxy-service' = @(3128, 3000) })
        $add = Get-YurunaPortMapPlan -Owner 'caching-proxy-service' -Owners $owners -HostPort @(3128, 80) -Discovered @(80, 2222, 3000, 3128, 9302)
        $add.Release | Should -Be @(80, 3000, 3128) -Because 'its own ports, and the unrecorded :80 it is about to install'
        $add.Conflict | Should -BeNullOrEmpty
        $steal = Get-YurunaPortMapPlan -Owner 'pool-control-service' -Owners $owners -HostPort @(2222)
        $steal.Conflict.Owner | Should -Be 'stash-service'
        $remove = Get-YurunaPortMapPlan -Owner 'caching-proxy-service' -Owners $owners -Discovered @(80, 2222, 3000, 3128, 9302) -Removing
        $remove.Release | Should -Be @(80, 3000, 3128, 9302) -Because 'an unrecorded forward predates owners and goes as it did before'
        $remove.Release | Should -Not -Contain 2222
    }
    It 'KVM: the cache''s port map leaves the stash forward in place' {
        $ledger = New-PortMapLedger -Owner @{ 'stash-service' = @(2222) }
        $script:Released = [System.Collections.Generic.List[int]]::new()
        $stubs = [scriptblock]::Create(@"
function Get-PortMapStatePath { '$ledger' }
function Get-KvmPortMapPort { [int[]]@(2222, 3128) }
function Remove-KvmPortForwarder { param(`$Port) `$script:Released.Add([int]`$Port) }
function Test-Ipv4Address { param(`$Address) `$true }
function Test-Path { param(`$LiteralPath) [string]`$LiteralPath -like '*systemd-socket-proxyd' }
function Invoke-YurunaSudo { param(`$Argument, `$InputText) @{ ExitCode = 0; Output = '' } }
"@)
        $added = Invoke-LiftedDriverFunction -Driver ubuntu.kvm -Name 'Add-PortMap' -Stubs $stubs -Call {
            Add-PortMap -VMIp '192.168.122.10' -Owner 'caching-proxy-service' -Port 3128 -Confirm:$false 6>$null }
        $added | Should -BeTrue
        @($script:Released) | Should -Be @(3128)
        $owners = Read-YurunaPortMapLedger -Path $ledger
        @($owners['stash-service'].mappings.hostPort) | Should -Be @(2222)
        @($owners['caching-proxy-service'].mappings.hostPort) | Should -Be @(3128)
        $script:Released.Clear()
        Invoke-LiftedDriverFunction -Driver ubuntu.kvm -Name 'Remove-PortMap' -Stubs $stubs -Call {
            Remove-PortMap -Owner 'caching-proxy-service' -Confirm:$false } | Should -BeTrue
        @($script:Released) | Should -Be @(3128)
        @((Read-YurunaPortMapLedger -Path $ledger).Keys) | Should -Be @('stash-service')
    }
    It 'UTM: a subset re-map leaves the owner''s other forwarders running, and a removal stops only its own' {
        $ledger = New-PortMapLedger -Owner @{ 'caching-proxy-service' = @(3000, 3128); 'stash-service' = @(2222) }
        $script:Stopped = [System.Collections.Generic.List[int]]::new()
        $script:Gone = [System.Collections.Generic.List[int]]::new()
        $stubs = [scriptblock]::Create(@"
function Get-PortMapStatePath { '$ledger' }
function Get-UtmPortMapPort { [int[]]@(@(2222, 3000, 3128) | Where-Object { `$script:Gone -notcontains `$_ }) }
function Stop-CachingProxyServiceForwarder { param(`$Port, [switch]`$Quiet) `$script:Stopped.Add([int]`$Port); `$script:Gone.Add([int]`$Port); `$true }
function Start-CachingProxyServiceForwarder { param(`$CacheIp, `$Port, `$VMPort, [switch]`$PrependProxyV1) `$true }
function Test-Ipv4Address { param(`$Address) `$true }
"@)
        Invoke-LiftedDriverFunction -Driver macos.utm -Name 'Add-PortMap' -Stubs $stubs -Call {
            Add-PortMap -VMIp '192.168.64.5' -Owner 'caching-proxy-service' -Port 3000 -Confirm:$false } | Should -BeTrue
        @($script:Stopped) | Should -BeNullOrEmpty -Because 'the per-cycle re-map asks for fewer ports than the start installed'
        @((Read-YurunaPortMapLedger -Path $ledger)['caching-proxy-service'].mappings.hostPort | Sort-Object) | Should -Be @(3000, 3128)
        Invoke-LiftedDriverFunction -Driver macos.utm -Name 'Remove-PortMap' -Stubs $stubs -Call {
            Remove-PortMap -Owner 'stash-service' -Confirm:$false } | Should -BeTrue
        @($script:Stopped) | Should -Be @(2222)
    }
    It 'Hyper-V: removing the cache''s forwards leaves the download agent''s' {
        $ledger = New-PortMapLedger -Owner @{ 'caching-proxy-service' = @(80, 3128); 'download-agent-service' = @(8082) }
        $script:Released = [System.Collections.Generic.List[int]]::new()
        $stubs = [scriptblock]::Create(@"
function Get-PortMapStatePath { param(`$RuntimeDir) '$ledger' }
function Get-HyperVPortMapPort { [int[]]@(80, 3128, 8082) }
function Remove-SinglePortMap { param(`$Port) `$script:Released.Add([int]`$Port) }
function Test-IsAdministrator { `$true }
"@)
        Invoke-LiftedDriverFunction -Driver windows.hyper-v -Name 'Remove-PortMap' -Stubs $stubs -Call {
            Remove-PortMap -Owner 'caching-proxy-service' -Confirm:$false 6>$null } | Should -BeTrue
        @($script:Released) | Should -Be @(80, 3128)
        @((Read-YurunaPortMapLedger -Path $ledger).Keys) | Should -Be @('download-agent-service')
    }
    It 'names an owner at every port-map call outside the drivers' {
        $missing = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test') -Recurse -Include '*.ps1', '*.psm1' -File) {
            if ($file.Name -like '*.Tests.ps1') { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($call in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Add-PortMap', 'Remove-PortMap') }, $true)) {
                if (-not ($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Owner' })) {
                    "$($file.Name):$($call.Extent.StartLineNumber)"
                }
            }
        }
        @($missing) | Should -BeNullOrEmpty
    }
}
