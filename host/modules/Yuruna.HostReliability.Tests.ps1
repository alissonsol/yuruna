<#PSScriptInfo
.VERSION 2026.10.11.1
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
