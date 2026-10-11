<#PSScriptInfo
.VERSION 2026.10.09
.GUID 42f51f9b-8197-490c-a7a7-1d4c95f6ed55
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test windows installer startup pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.EXTERNALMODULEDEPENDENCIES Pester
#>

#requires -version 7

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fixture commands preserve the signatures called by isolated production code.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production blocks consume fixture variables through dynamic scope.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Test-local stubs prevent importing host drivers, launching consoles or changing files.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test-local host and keyboard stubs perform no host mutation.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Fixture callbacks accept the production Confirm argument but change no host state.')]
[CmdletBinding()]
param()

<#
.SYNOPSIS
    Exercise unattended Windows DVD startup without operating a hypervisor.
.DESCRIPTION
    Short real deadlines verify the bounded keyboard retry window. The host
    fixtures run only the installer-start region or an extracted lifecycle
    function, with all hypervisor and console calls replaced by local stubs.
#>

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.WindowsInstaller.psm1') -Force -DisableNameChecking

    function Get-WindowsInstallerFunction {
        param([string]$RelativePath, [string]$Name)
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $RelativePath), [ref]$null, [ref]$errors)
        if ($errors) { throw $errors[0].Message }
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
        if (-not $function) { throw "Missing function $Name in $RelativePath" }
        return $function.Extent.Text
    }

    function Get-WindowsInstallerStartRegion {
        param([string]$Platform)
        $source = Get-Content (Join-Path $script:RepoRoot "host/$Platform/guest.windows.11/New-VM.ps1") -Raw
        $start = $source.IndexOf('# --- REGION: Start Windows installer', [StringComparison]::Ordinal)
        if ($start -lt 0) { throw "Missing Windows installer startup region on $Platform" }
        $end = $source.IndexOf('# --- REGION:', $start + 15, [StringComparison]::Ordinal)
        if ($end -lt 0) { $end = $source.Length }
        # Native qualified commands resolve to fixture stubs here; none of the
        # builder's disk creation, VM replacement or networking phases execute.
        return $source.Substring($start, $end - $start).Replace('Hyper-V\', '').Replace('Test.Transport\', '')
    }

    function New-WindowsInstallerVncFixture {
        param([switch]$NeverConnect)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $hostDir = Join-Path $root 'host/macos.utm/modules'
        $transportDir = Join-Path $root 'test/modules'
        $null = New-Item -ItemType Directory -Path $hostDir, $transportDir -Force
        $hostModule = @'
function Get-VncPortForVm {
    param($VMName)
    $portFile = Join-Path $PSScriptRoot '../../../test/modules/port.txt'
    if (Test-Path -LiteralPath $portFile) { return [int][IO.File]::ReadAllText($portFile) }
    return 5900
}
function Get-VncDisplayFromBundle {
    param($VMName)
    $portFile = Join-Path $PSScriptRoot '../../../test/modules/port.txt'
    if (Test-Path -LiteralPath $portFile) { return [int][IO.File]::ReadAllText($portFile) - 5900 }
    return -1
}
Export-ModuleMember -Function Get-VncPortForVm, Get-VncDisplayFromBundle
'@
        $transportModule = @'
function Send-KeyVNC {
    param($VMName, $KeyName, $Port)
    [IO.File]::AppendAllText((Join-Path $PSScriptRoot 'attempts.log'), ('{0}:{1}:{2}' -f $VMName, $KeyName, $Port) + "`n")
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'never-connect')) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'started'))) { return $false }
    if ($Port -ne 5929 -or $KeyName -ne 'Space') { return $false }
    [IO.File]::AppendAllText((Join-Path $PSScriptRoot 'keys.log'), ('{0}:{1}:{2}' -f $VMName, $KeyName, $Port) + "`n")
    return $true
}
function Disconnect-VNC {
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'disconnected'), 'closed')
}
Export-ModuleMember -Function Send-KeyVNC, Disconnect-VNC
'@
        Set-Content -LiteralPath (Join-Path $hostDir 'Yuruna.Host.psm1') -Value $hostModule -Encoding utf8
        Set-Content -LiteralPath (Join-Path $transportDir 'Test.Transport.psm1') -Value $transportModule -Encoding utf8
        if ($NeverConnect) { [IO.File]::WriteAllText((Join-Path $transportDir 'never-connect'), 'fixture') }
        return @{ RepoRoot = $root; TransportDir = $transportDir }
    }
}

Describe 'Windows installer boot-key window' {
    It 'starts once before sending keys and continues after an early accepted key' {
        $calls = [Collections.Generic.List[string]]::new()
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        $output = @(Start-YurunaWindowsInstaller -VMName 'fixture-windows' -BootKeySeconds 1 -PollMilliseconds 100 -Confirm:$false -StartVM {
            $calls.Add('start')
            'native start output'
        } -SendBootKey {
            $calls.Add('key')
            return $true
        })
        $elapsed.Stop()
        $output.Count | Should -Be 0
        $calls[0] | Should -Be 'start'
        @($calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -eq 'key' }).Count | Should -BeGreaterThan 1
        # An accepted transport write before the DVD prompt appears is not
        # evidence that the loader consumed it; retry for the entire window.
        $elapsed.Elapsed.TotalMilliseconds | Should -BeGreaterOrEqual 900
        $elapsed.Elapsed.TotalSeconds | Should -BeLessThan 5
    }

    It 'recovers when the guest keyboard is initially unavailable or throws' {
        $attempts = [Collections.Generic.List[int]]::new()
        { Start-YurunaWindowsInstaller -VMName 'fixture-windows' -BootKeySeconds 1 -PollMilliseconds 100 -Confirm:$false -StartVM {} -SendBootKey {
            $attempts.Add($attempts.Count + 1)
            if ($attempts.Count -eq 1) { return $false }
            if ($attempts.Count -eq 2) { throw 'Keyboard is not ready yet.' }
            return $true
        } } | Should -Not -Throw
        $attempts.Count | Should -BeGreaterThan 2
    }

    It 'fails within the deadline when no key can be delivered' {
        $attempts = [Collections.Generic.List[int]]::new()
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        { Start-YurunaWindowsInstaller -VMName 'fixture-windows' -BootKeySeconds 1 -PollMilliseconds 100 -Confirm:$false -StartVM {} -SendBootKey {
            $attempts.Add(1)
            return $false
        } } | Should -Throw
        $elapsed.Stop()
        $attempts.Count | Should -BeGreaterThan 1
        $elapsed.Elapsed.TotalSeconds | Should -BeLessThan 5
    }

    It 'rejects a truthy failure record as proof that input was delivered' {
        { Start-YurunaWindowsInstaller -VMName 'fixture-windows' -BootKeySeconds 1 -PollMilliseconds 100 -Confirm:$false -StartVM {} -SendBootKey {
            return @{ success = $false; errorMessage = 'Disconnected' }
        } } | Should -Throw
    }

    It 'propagates a startup failure before attempting keyboard input' {
        $calls = [Collections.Generic.List[string]]::new()
        { Start-YurunaWindowsInstaller -VMName 'fixture-windows' -BootKeySeconds 1 -Confirm:$false -StartVM {
            $calls.Add('start')
            throw 'Fixture startup failed.'
        } -SendBootKey {
            $calls.Add('key')
            return $true
        } } | Should -Throw '*Fixture startup failed*'
        $calls.ToArray() | Should -Be @('start')
    }

    It 'does not start a guest or send input for WhatIf' {
        $calls = [Collections.Generic.List[string]]::new()
        Start-YurunaWindowsInstaller -VMName 'fixture-windows' -BootKeySeconds 1 -WhatIf -StartVM {
            $calls.Add('start')
        } -SendBootKey {
            $calls.Add('key')
            return $true
        }
        $calls.Count | Should -Be 0
    }
}

Describe 'Already running UTM installer survives the runner start step' {
    It 'returns success before rewriting its VNC configuration or saved state' {
        . ([scriptblock]::Create((Get-WindowsInstallerFunction 'host/macos.utm/modules/Yuruna.Host.psm1' 'Start-UtmVM')))
        $script:LifecycleCalls = [Collections.Generic.List[string]]::new()
        function Format-YurunaOperatorMessage { param($Key, $Arguments) return $Key }
        function Test-Path { return $true }
        function Get-VMStateRecord {
            param($VMName)
            $VMName | Should -Be 'fixture-windows'
            $script:LifecycleCalls.Add('state')
            return @{ State = 'running' }
        }
        function Remove-Item { throw 'A running installer must retain its saved state.' }
        function Find-FreeVncDisplay { throw 'A running installer must retain its VNC display.' }
        function Start-UtmDialogWatchdog { throw 'The already running guest needs no new watchdog.' }
        function Start-UtmDetachedLaunch { throw 'The already running guest needs no new launch.' }
        function Invoke-UtmVMStartWithRetry { throw 'The running guest must not be cold-started.' }
        $result = Start-UtmVM -VMName 'fixture-windows' -Confirm:$false
        $result.success | Should -BeTrue
        $script:LifecycleCalls.ToArray() | Should -Be @('state')
    }
}

Describe 'UTM Windows VNC provisioning' {
    It 'renders a local VNC endpoint into the actual Windows bundle template' {
        $path = Join-Path $script:RepoRoot 'host/macos.utm/guest.windows.11/New-VM.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $values = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$plistValues'
        }, $true)
        $values | Should -Not -BeNullOrEmpty
        function Get-VncDisplayForVm { return 29 }
        $VMName = 'fixture-windows'
        $VmUuid = $DiskId = $IsoId = $SeedId = '42f51f9b-8197-490c-a7a7-1d4c95f6ed55'
        $MacAddress = '52:54:00:01:02:03'
        $vmCores = 4
        . ([scriptblock]::Create($values.Extent.Text))
        . ([scriptblock]::Create((Get-WindowsInstallerFunction 'host/macos.utm/modules/Yuruna.Host.psm1' 'Write-UtmBundleConfiguration')))
        function Invoke-UtmHostTool { return @{ ExitCode = 0 } }
        function Test-UtmBoundedResultComplete { return $true }
        $bundle = Join-Path $TestDrive 'rendered-windows.utm'
        $null = New-Item -ItemType Directory -Path $bundle
        Write-UtmBundleConfiguration -TemplatePath (Join-Path (Split-Path $path -Parent) 'config.plist.template') -BundlePath $bundle -Replacement $plistValues -Confirm:$false
        [xml]$config = Get-Content -LiteralPath (Join-Path $bundle 'config.plist') -Raw
        $arguments = @($config.SelectNodes("/plist/dict/key[.='QEMU']/following-sibling::dict[1]/key[.='AdditionalArguments']/following-sibling::array[1]/string") | ForEach-Object { $_.InnerText })
        $vncIndex = [Array]::IndexOf($arguments, '-vnc')
        $vncIndex | Should -BeGreaterOrEqual 0
        $arguments[$vncIndex + 1] | Should -Be '127.0.0.1:29,share=force-shared'
        # QEMU refuses to start a VNC console on a GL display device.
        $displays = @($config.SelectNodes("/plist/dict/key[.='Display']/following-sibling::array[1]/dict/key[.='Hardware']/following-sibling::string[1]") | ForEach-Object { $_.InnerText })
        $displays | Should -Not -BeNullOrEmpty
        $displays | Where-Object { $_ -match '-gl($|-)' } | Should -BeNullOrEmpty
    }

    It 'arms the installer keyboard only after successful port allocation (<PatchResult>)' -ForEach @(
        @{ PatchResult = $true }, @{ PatchResult = $false }
    ) {
        . ([scriptblock]::Create((Get-WindowsInstallerFunction 'host/macos.utm/modules/Yuruna.Host.psm1' 'Start-UtmVM')))
        $script:AllocationCalls = [Collections.Generic.List[string]]::new()
        $script:AssignedDisplay = 10
        $script:PatchResult = $PatchResult
        function Format-YurunaOperatorMessage { param($Key) return $Key }
        function Test-Path { param($Path) return $Path -notlike '*vmstate' }
        function Get-VMStateRecord { return @{ State = 'stopped' } }
        function Get-VncDisplayForVm { return 10 }
        function Get-ClaimedVncDisplay { return @(10) }
        function Find-FreeVncDisplay { return 29 }
        function Get-VncDisplayFromBundle { return $script:AssignedDisplay }
        function Set-VncDisplayInBundle {
            [CmdletBinding(SupportsShouldProcess)]
            param($VMName, $Display)
            $script:AllocationCalls.Add('allocate')
            if ($script:PatchResult) { $script:AssignedDisplay = $Display }
            return $script:PatchResult
        }
        function Start-UtmDialogWatchdog { $script:AllocationCalls.Add('watchdog') }
        function Start-UtmDetachedLaunch {
            [CmdletBinding(SupportsShouldProcess)]
            param($Tool, $ArgumentList)
            $script:AllocationCalls.Add('launch')
        }
        function Invoke-UtmVMStartWithRetry {
            [CmdletBinding(SupportsShouldProcess)]
            [OutputType([hashtable])]
            param($VMName)
            $script:AllocationCalls.Add('native-start')
            return @{ success = $true }
        }
        $result = Start-UtmVM -VMName 'fixture-windows' -Confirm:$false -BeforeLaunch {
            $script:AssignedDisplay | Should -Be 29
            $script:AllocationCalls.Add('arm')
        }
        $result.success | Should -Be $PatchResult
        if ($PatchResult) {
            $script:AllocationCalls.ToArray() | Should -Be @('allocate', 'arm', 'watchdog', 'launch', 'native-start')
        } else {
            $script:AllocationCalls.ToArray() | Should -Be @('allocate')
        }
    }
}

Describe 'Windows builders start before sending the DVD key' {
    BeforeEach {
        $script:StartupCalls = [Collections.Generic.List[string]]::new()
        $script:StartupFailure = $false
        function Import-Module { param($Name) }
        function Start-YurunaWindowsInstaller {
            [CmdletBinding(SupportsShouldProcess)]
            param($VMName, [scriptblock]$StartVM, [scriptblock]$SendBootKey)
            $VMName | Should -Be 'fixture-windows'
            $null = & $StartVM
            $null = & $SendBootKey
            $script:StartupCalls.Add('boot-complete')
        }
        function Start-YurunaWindowsInstallerVnc {
            [CmdletBinding(SupportsShouldProcess)]
            param($VMName, $RepoRoot, [scriptblock]$StartVM)
            $VMName | Should -Be 'fixture-windows'
            $RepoRoot | Should -Be $script:RepoRoot
            $armed = [Threading.ManualResetEventSlim]::new($false)
            try {
                $null = & $StartVM $armed
                $armed.IsSet | Should -BeTrue
            } finally { $armed.Dispose() }
            # The worker owns input delivery; this fixture verifies the
            # builder wires startup through it, rather than starting first.
            $script:StartupCalls.Add('key')
            $script:StartupCalls.Add('boot-complete')
        }
        function Start-VM {
            [CmdletBinding()]
            param($Name)
            $Name | Should -Be 'fixture-windows'
            $script:StartupCalls.Add('start')
            if ($script:StartupFailure) { throw 'Fixture startup failed.' }
        }
        function Start-UtmVM {
            [CmdletBinding(SupportsShouldProcess)]
            [OutputType([hashtable])]
            param($VMName, [scriptblock]$BeforeLaunch)
            $VMName | Should -Be 'fixture-windows'
            $script:StartupCalls.Add('start')
            if (-not $script:StartupFailure -and $BeforeLaunch) { $null = & $BeforeLaunch }
            return @{ success = (-not $script:StartupFailure); errorMessage = 'Fixture startup failed.' }
        }
        function Send-KeyHyperV {
            param($VMName, $KeyName)
            $VMName | Should -Be 'fixture-windows'
            $KeyName | Should -Be 'Space'
            $script:StartupCalls.Add('key')
            return $true
        }
        function Get-VncPortForVm {
            param($VMName)
            $VMName | Should -Be 'fixture-windows'
            return 5929
        }
        function Send-KeyVNC {
            param($VMName, $KeyName, $Port)
            $VMName | Should -Be 'fixture-windows'
            $KeyName | Should -Be 'Space'
            $Port | Should -Be 5929
            $script:StartupCalls.Add('key')
            return $true
        }
        function Disconnect-VNC { $script:StartupCalls.Add('disconnect') }
        function Start-Process { throw 'Creating the VM must not open a console window.' }
    }

    It 'starts and delivers Space through the guest transport on <Platform>' -ForEach @(
        @{ Platform = 'windows.hyper-v' }, @{ Platform = 'macos.utm' }
    ) {
        $VMName = 'fixture-windows'
        $repoRoot = $_utmRepoRoot = $script:RepoRoot
        $output = @(& ([scriptblock]::Create((Get-WindowsInstallerStartRegion $Platform))))
        $output.Count | Should -Be 0
        $script:StartupCalls[0] | Should -Be 'start'
        $script:StartupCalls[1] | Should -Be 'key'
        $script:StartupCalls[2] | Should -Be 'boot-complete'
        if ($Platform -eq 'macos.utm') {
            $script:StartupCalls.ToArray() | Should -Be @('start', 'key', 'boot-complete')
        } else {
            # Match virt-install --noautoconsole: the installer starts without
            # requiring a VMConnect window or stealing the operator's focus.
            $script:StartupCalls.ToArray() | Should -Be @('start', 'key', 'boot-complete')
        }
    }

    It 'propagates startup failure before sending any DVD key on <Platform>' -ForEach @(
        @{ Platform = 'windows.hyper-v' }, @{ Platform = 'macos.utm' }
    ) {
        $VMName = 'fixture-windows'
        $repoRoot = $_utmRepoRoot = $script:RepoRoot
        $script:StartupFailure = $true
        { & ([scriptblock]::Create((Get-WindowsInstallerStartRegion $Platform))) } | Should -Throw '*Fixture startup failed*'
        $script:StartupCalls[0] | Should -Be 'start'
        $script:StartupCalls.ToArray() | Should -Not -Contain 'key'
        $script:StartupCalls.ToArray() | Should -Not -Contain 'console'
    }
}

Describe 'Host-specific Windows start sequences preserve KVM input' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.SequenceResolve.psm1') -Force -DisableNameChecking
        Import-Module powershell-yaml -DisableNameChecking
    }
    It 'resolves the appropriate startup actions for <HostType>' -ForEach @(
        @{ HostType = 'host.ubuntu.kvm'; ExpectedFile = 'start.guest.windows.11.yml'; NeedsKey = $true },
        @{ HostType = 'host.windows.hyper-v'; ExpectedFile = 'start.guest.windows.11.windows.hyper-v.yml'; NeedsKey = $false },
        @{ HostType = 'host.macos.utm'; ExpectedFile = 'start.guest.windows.11.macos.utm.yml'; NeedsKey = $false }
    ) {
        $path = Resolve-SequencePath -SequencesDir (Join-Path $script:RepoRoot 'test/sequences') -Name 'start.guest.windows.11' -HostType $HostType -RepoRoot $TestDrive
        Split-Path $path -Leaf | Should -Be $ExpectedFile
        $sequence = Get-Content -LiteralPath $path -Raw | ConvertFrom-Yaml
        $steps = @($sequence.component)
        if ($NeedsKey) {
            @($steps | Where-Object { $_.action -eq 'pressKey' }).Count | Should -BeGreaterThan 0
        } else {
            $steps.Count | Should -Be 0
        }
    }
}

Describe 'UTM boot input runs while synchronous startup is blocked' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.WindowsInstallerVnc.psm1') -Force -DisableNameChecking
    }

    It 'delivers Space before startup returns and follows the assigned VNC port' {
        $fixture = New-WindowsInstallerVncFixture
        $seenDuringStartup = [Collections.Generic.List[bool]]::new()
        $silentBeforeArming = [Collections.Generic.List[bool]]::new()
        [IO.File]::WriteAllText((Join-Path $fixture.TransportDir 'port.txt'), '5910')
        Start-YurunaWindowsInstallerVnc -VMName 'fixture-windows' -RepoRoot $fixture.RepoRoot -ReadyTimeoutSeconds 5 -KeyDeliveryTimeoutSeconds 3 -BootKeySeconds 1 -KeyIntervalMilliseconds 25 -Confirm:$false -StartVM {
            param($KeyboardArmed)
            # The initial bundle can name another VM's occupied port. No
            # connection or input is allowed before startup finishes allocation.
            [Threading.Thread]::Sleep(100)
            $silentBeforeArming.Add((-not (Test-Path -LiteralPath (Join-Path $fixture.TransportDir 'attempts.log'))))
            [IO.File]::WriteAllText((Join-Path $fixture.TransportDir 'port.txt'), '5929')
            [IO.File]::WriteAllText((Join-Path $fixture.TransportDir 'started'), 'running')
            $KeyboardArmed.Set()
            $wait = [Diagnostics.Stopwatch]::StartNew()
            do {
                if (Test-Path -LiteralPath (Join-Path $fixture.TransportDir 'keys.log')) { break }
                [Threading.Thread]::Sleep(25)
            } while ($wait.Elapsed.TotalSeconds -lt 2)
            $seenDuringStartup.Add((Test-Path -LiteralPath (Join-Path $fixture.TransportDir 'keys.log')))
        }
        $silentBeforeArming.ToArray() | Should -Be @($true)
        $seenDuringStartup.ToArray() | Should -Be @($true)
        $keys = Get-Content -LiteralPath (Join-Path $fixture.TransportDir 'keys.log')
        $keys.Count | Should -BeGreaterThan 1
        $keys[0] | Should -Be 'fixture-windows:Space:5929'
        @(Get-Content -LiteralPath (Join-Path $fixture.TransportDir 'attempts.log') | Where-Object { $_ -ne 'fixture-windows:Space:5929' }).Count | Should -Be 0
        Join-Path $fixture.TransportDir 'disconnected' | Should -Exist
    }

    It 'propagates startup failure and disposes the keyboard worker' {
        $fixture = New-WindowsInstallerVncFixture
        $jobsBefore = @(Get-Job | Select-Object -ExpandProperty Id)
        { Start-YurunaWindowsInstallerVnc -VMName 'fixture-windows' -RepoRoot $fixture.RepoRoot -ReadyTimeoutSeconds 5 -KeyDeliveryTimeoutSeconds 3 -BootKeySeconds 1 -KeyIntervalMilliseconds 25 -Confirm:$false -StartVM {
            throw 'Fixture synchronous startup failed.'
        } } | Should -Throw '*Fixture synchronous startup failed*'
        @(Get-Job | Where-Object { $_.Id -notin $jobsBefore }).Count | Should -Be 0
    }

    It 'fails when startup succeeds but the VNC keyboard never becomes available' {
        $fixture = New-WindowsInstallerVncFixture -NeverConnect
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        { Start-YurunaWindowsInstallerVnc -VMName 'fixture-windows' -RepoRoot $fixture.RepoRoot -ReadyTimeoutSeconds 5 -KeyDeliveryTimeoutSeconds 1 -BootKeySeconds 1 -KeyIntervalMilliseconds 25 -Confirm:$false -StartVM {
            param($KeyboardArmed)
            [IO.File]::WriteAllText((Join-Path $fixture.TransportDir 'port.txt'), '5929')
            [IO.File]::WriteAllText((Join-Path $fixture.TransportDir 'started'), 'running')
            $KeyboardArmed.Set()
        } } | Should -Throw
        $elapsed.Stop()
        $elapsed.Elapsed.TotalSeconds | Should -BeLessThan 10
        Join-Path $fixture.TransportDir 'keys.log' | Should -Not -Exist
        Join-Path $fixture.TransportDir 'attempts.log' | Should -Exist
        Join-Path $fixture.TransportDir 'disconnected' | Should -Exist
    }
}
