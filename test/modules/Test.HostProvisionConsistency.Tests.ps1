<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 427dc7e5-42e7-4d34-bef6-83be459c7402
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host provisioning consistency
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

<#
.SYNOPSIS
    Verify host provisioning failure boundaries without operating a hypervisor.
.DESCRIPTION
    Runs the service builders' disk-capacity gate in child PowerShell processes,
    exercises ISO adoption against temporary files, and calls the real provider
    lifecycle exports with module-local native-command stubs.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Pwsh = [Environment]::ProcessPath
    $script:FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-host-provision-' + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:FixtureRoot
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking

    function Invoke-ProvisionFixture {
        param([string]$Body, [string[]]$Argument = @())
        $fixture = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString() + '.ps1')
        # Extracted branches retain their production renderer dependency. Put
        # the import after any parameter block so child argument binding stays
        # identical to the original fixture.
        $ast = [Management.Automation.Language.Parser]::ParseInput($Body, [ref]$null, [ref]$null)
        $offset = if ($ast.ParamBlock) { $ast.ParamBlock.Extent.EndOffset } else { 0 }
        $adapter = (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1').Replace("'", "''")
        $Body = $Body.Insert($offset, "`nImport-Module '$adapter' -DisableNameChecking`n")
        Set-Content -LiteralPath $fixture -Value $Body -Encoding utf8
        $output = @(& $script:Pwsh -NoLogo -NoProfile -File $fixture @Argument 2>&1)
        return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }

    function Get-ProvisionAst {
        param([string]$Path)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        if ($errors) { throw "$Path does not parse: $($errors[0].Message)" }
        return $ast
    }

    function Get-EffectiveGuestBuilderSource {
        param([string]$Path)
        $source = Get-Content -LiteralPath $Path -Raw
        if ($source -match 'modules/New-UbuntuServerVM.ps1') {
            $shared = Join-Path (Split-Path (Split-Path $Path -Parent) -Parent) 'modules/New-UbuntuServerVM.ps1'
            return Get-Content -LiteralPath $shared -Raw
        }
        return $source
    }

    function Invoke-UtmCacheFixture {
        param([string]$State, [string]$Probe = 'unreachable', [string]$Binding = 'unbound')
        $source = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'host/macos.utm/modules/New-UbuntuServerVM.ps1') -Raw
        $start = $source.IndexOf('# --- REGION: Detect the caching-proxy service', [StringComparison]::Ordinal)
        $end = $source.IndexOf('# --- REGION: Build the autoinstall apt block', $start, [StringComparison]::Ordinal)
        if ($start -lt 0 -or $end -le $start) { throw 'Missing cache selection region' }
        $calls = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString() + '.calls')
        $body = @'
param([string]$State, [string]$Probe, [string]$Calls, [string]$CachingProxyServiceUrl)
$ErrorActionPreference = 'Stop'
function Get-VMStateRecord {
    param([string]$VMName)
    if ($VMName -ne 'yuruna-caching-proxy-service') { throw 'Wrong cache VM' }
    Add-Content -LiteralPath $Calls -Value 'state'
    if ($State -eq 'exception') { throw 'Fixture state query failed' }
    [pscustomobject]@{ State = $State; Reason = 'fixture-state' }
}
function Test-CachingProxyServiceAvailable {
    Add-Content -LiteralPath $Calls -Value 'proxy'
    if ($Probe -eq 'exception') { throw 'Fixture proxy query failed' }
    if ($Probe -eq 'reachable') { return 'http://192.0.2.7:3128' }
    return $null
}
'@
        $body += "`n" + $source.Substring($start, $end - $start)
        $body += "`n'AFTER_CACHE_GATE'; @{ Url = `$CachingProxyServiceUrl } | ConvertTo-Json -Compress"
        $arguments = @('-State', $State, '-Probe', $Probe, '-Calls', $calls)
        if ($Binding -ne 'unbound') {
            $arguments += @('-CachingProxyServiceUrl', $(if ($Binding -eq 'empty') { '' } else { 'http://192.0.2.8:3128' }))
        }
        $run = Invoke-ProvisionFixture -Body $body -Argument $arguments
        $order = if (Test-Path -LiteralPath $calls) { @(Get-Content -LiteralPath $calls) } else { @() }
        return @{ ExitCode = $run.ExitCode; Output = $run.Output; Calls = @($order) }
    }

    function Invoke-UtmRemovalFixture {
        param([string]$Stop = 'success', [string]$PowerOff = 'confirmed', [string]$Registration = 'absent', [switch]$Preview)
        $ast = Get-ProvisionAst (Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1')
        $function = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-UtmTestVM'
            }, $true)
        if (-not $function) { throw 'Missing UTM removal function' }
        $fixtureHome = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
        $body = @'
param([string]$FixtureHome, [string]$Stop, [string]$PowerOff, [string]$Registration, [switch]$Preview)
$ErrorActionPreference = 'Stop'
Set-Variable -Name HOME -Value $FixtureHome -Force
$bundle = Join-Path $HOME 'yuruna/guest.nosync/test-replacement.utm'
$disk = Join-Path $bundle 'Data/disk.qcow2'
$null = New-Item -ItemType Directory -Path (Split-Path $disk -Parent) -Force
[IO.File]::WriteAllText($disk, 'retained guest bytes')
$script:Order = [Collections.Generic.List[string]]::new()
function Invoke-UtmctlLifecycle {
    param([string]$Verb, [string]$VMName)
    if ($Verb -ne 'stop' -or $VMName -ne 'test-replacement') { throw 'Wrong lifecycle call' }
    $script:Order.Add('stop')
    @{ OutcomeKnown = ($Stop -ne 'unknown'); ExitCode = $(if ($Stop -eq 'success') { 0 } else { 1 }); FailureKind = 'none' }
}
function Wait-UtmVMPoweredOff {
    param([string]$VMName)
    if ($VMName -ne 'test-replacement') { throw 'Wrong power-off call' }
    $script:Order.Add('poweroff')
    return ($PowerOff -in @('confirmed', 'absent'))
}
function Remove-UtmVMRegistration {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$VMName)
    if ($VMName -ne 'test-replacement') { throw 'Wrong unregister call' }
    $script:Order.Add('unregister')
    return ($Registration -in @('absent', 'files-failed'))
}
function Remove-UtmBundleWithRetry {
    param([string]$Path)
    if ($Path -ne $bundle) { throw 'Removal escaped fixture' }
    $script:Order.Add('bundle')
    if ($Registration -eq 'files-failed') { return $false }
    Remove-Item -LiteralPath $Path -Recurse -Force
    return $true
}
'@
        $body += "`n" + $function.Extent.Text
        $body += @'

$result = Remove-UtmTestVM -VMName 'test-replacement' -Confirm:$false -WhatIf:$Preview
@{ Result = [bool]$result; Order = $script:Order.ToArray(); DiskExists = (Test-Path -LiteralPath $disk)
    Bytes = $(if (Test-Path -LiteralPath $disk) { [IO.File]::ReadAllText($disk) } else { '' }) } | ConvertTo-Json -Compress
'@
        $arguments = @('-FixtureHome', $fixtureHome, '-Stop', $Stop, '-PowerOff', $PowerOff, '-Registration', $Registration)
        if ($Preview) { $arguments += '-Preview' }
        $run = Invoke-ProvisionFixture -Body $body -Argument $arguments
        if ($run.ExitCode -ne 0) { throw $run.Output }
        return ($run.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
    }

    function Invoke-UbuntuWrapperFixture {
        param([string]$Release, [string]$Workflow, [string]$Invocation = '', [int]$ExitCode = 0)
        $provider = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
        $guest = Join-Path $provider "guest.ubuntu.server.$Release"
        $modules = Join-Path $provider 'modules'
        $null = New-Item -ItemType Directory -Path $guest, $modules
        $wrapper = Join-Path $guest "$Workflow.ps1"
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "host/windows.hyper-v/guest.ubuntu.server.$Release/$Workflow.ps1") -Destination $wrapper
        $helper = if ($Workflow -eq 'New-VM') { 'New-UbuntuServerVM.ps1' } else { 'Get-UbuntuServerImage.ps1' }
        $body = @'
param(
    [string]$VMName, [string]$CachingProxyServiceUrl, [string]$Username,
    [string]$Hostname, [string]$MemoryStartupBytes, [string]$Cores,
    [string]$ExposeVirtualizationExtensions, [switch]$daily,
    [string]$Release, [string]$GuestScriptRoot, [string]$EnvironmentErrorKey
)
$captured = @{} + $PSBoundParameters
foreach ($name in @($captured.Keys)) {
    if ($captured[$name] -is [switch]) { $captured[$name] = [bool]$captured[$name] }
}
$captured | ConvertTo-Json -Compress
exit FIXTURE_EXIT
'@
        Set-Content -LiteralPath (Join-Path $modules $helper) -Value $body.Replace('FIXTURE_EXIT', [string]$ExitCode) -Encoding utf8
        $escaped = $wrapper.Replace("'", "''")
        $run = Invoke-ProvisionFixture -Body ("`$global:LASTEXITCODE = 91`n& '$escaped' $Invocation`nexit `$LASTEXITCODE")
        return @{ ExitCode = $run.ExitCode; Arguments = ($run.Output | ConvertFrom-Json -AsHashtable); GuestScriptRoot = $guest }
    }

    $script:ServiceBuilders = @(Get-ChildItem (Join-Path $script:RepoRoot 'host/*/guest.*-service/New-VM.ps1'))
    $script:GuestBuilders = @(Get-ChildItem (Join-Path $script:RepoRoot 'host/*/guest.*/New-VM.ps1'))
    $script:UtmFixture = @'
param([string]$ModulePath, [string]$Mode, [int]$NativeExitCode)
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
& $module {
    param($ExitCode)
    $script:NativeExitCode = $ExitCode
    $script:StopCalls = [Collections.Generic.List[string]]::new()
    $script:WatchdogStops = 0
    function script:Invoke-UtmctlLifecycle {
        param([string]$Verb, [string]$VMName, [switch]$Kill, $Deadline, [int]$TimeoutSeconds, [switch]$Quiet)
        $script:StopCalls.Add("$Verb $VMName$(if ($Kill) { ' --kill' })")
        return @{
            ExitCode = $script:NativeExitCode; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $true
            DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; DeadlineExhausted = $false
            Verb = $Verb; VMName = $VMName; Kill = [bool]$Kill; OutcomeKnown = $true; FailureKind = 'none'; Text = ''
        }
    }
    function script:Stop-UtmDialogWatchdog { $script:WatchdogStops++ }
    function script:Start-Sleep { param([int]$Seconds) }
} $NativeExitCode
$result = switch ($Mode) {
    'graceful' { Yuruna.Host\Stop-VM -VMName 'test-provision' -Confirm:$false }
    'force'   { Yuruna.Host\Stop-VM -VMName 'test-provision' -Force -Confirm:$false }
    'direct-force' { Yuruna.Host\Stop-VMForce -VMName 'test-provision' -Confirm:$false }
    'whatif'  { Yuruna.Host\Stop-VM -VMName 'test-provision' -Force -WhatIf }
    'direct-whatif' { Yuruna.Host\Stop-VMForce -VMName 'test-provision' -WhatIf }
}
$calls = @(& $module { $script:StopCalls.ToArray() })
$watchdogStops = & $module { $script:WatchdogStops }
@{ Result = [bool]$result; Calls = $calls; WatchdogStops = $watchdogStops } | ConvertTo-Json -Compress
'@
    $script:KvmFixture = @'
param([string]$ModulePath, [string]$Mode, [string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$vmDir = Join-Path $ScratchRoot 'test-provision'
$null = New-Item -ItemType Directory -Path $vmDir -Force
Set-Content -LiteralPath (Join-Path $vmDir 'disk.qcow2') -Value 'retained guest data'
& $module {
    param($Mode, $ScratchRoot)
    $script:FixtureMode = $Mode
    $script:VmRootDir = $ScratchRoot
    function script:virsh {
        $global:LASTEXITCODE = 1
        if ($args[2] -eq 'undefine' -and $script:FixtureMode -like 'undefined-*') {
            $global:LASTEXITCODE = 0
        }
        if ($args[2] -eq 'list' -and $script:FixtureMode -notin @('inventory-failed', 'undefined-inventory-failed')) {
            $global:LASTEXITCODE = 0
            if ($script:FixtureMode -in @('present', 'undefined-present')) { 'test-provision' }
        }
    }
} $Mode $ScratchRoot
$result = Yuruna.Host\Remove-VM -VMName 'test-provision' -Confirm:$false
@{ Result = [bool]$result; DiskExists = (Test-Path -LiteralPath (Join-Path $vmDir 'disk.qcow2')) } | ConvertTo-Json -Compress
'@
}

AfterAll {
    if ($script:FixtureRoot -and (Test-Path -LiteralPath $script:FixtureRoot)) {
        Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force
    }
}

Describe 'Per-guest builder log-module lifetime' {
    It 'uses the same feature-detected non-forcing log setup in every New-VM builder' {
        Assert-True ($script:GuestBuilders.Count -eq 25) 'all per-guest New-VM builders must be covered'
        $canonicalBlock = @'
# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }
'@
        foreach ($builder in $script:GuestBuilders) {
            $text = (Get-EffectiveGuestBuilderSource -Path $builder.FullName) -replace "`r`n", "`n"
            Assert-True ($text.Replace('$GuestScriptRoot', '$PSScriptRoot').Contains($canonicalBlock)) "$($builder.FullName) must reuse the loaded log module without -Force"
        }
    }
}

Describe 'Per-guest builder phase order' {
    It 'keeps the canonical host-independent provisioning subsequence in every New-VM builder' {
        $markers = @(
            '# --- REGION: Log level from environment',
            '# --- REGION: Seek the base image',
            '# --- REGION: Remove existing VM',
            '# --- REGION: Create copies and files for VM'
        )
        foreach ($builder in $script:GuestBuilders) {
            $text = Get-EffectiveGuestBuilderSource -Path $builder.FullName
            $previous = -1
            foreach ($marker in $markers) {
                $current = $text.IndexOf($marker, [StringComparison]::Ordinal)
                Assert-True ($current -gt $previous) "$($builder.FullName) must keep the ordered provisioning phase '$marker'"
                $previous = $current
            }
        }
    }

    It 'delays destructive KVM guest-disk replacement until seed generation succeeds' {
        $kvmDiskPhases = @{
            'host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1' = '# --- REGION: Copy base image -> per-VM disk'
            'host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1'  = '# --- REGION: Create empty install target'
            'host/ubuntu.kvm/guest.ubuntu.server.26/New-VM.ps1'  = '# --- REGION: Create empty install target'
        }
        foreach ($relativePath in $kvmDiskPhases.Keys) {
            $text = Get-EffectiveGuestBuilderSource -Path (Join-Path $script:RepoRoot $relativePath)
            $seedPhase = $text.IndexOf('# --- REGION: Generate cloud-init seed ISO', [StringComparison]::Ordinal)
            $diskPhase = $text.IndexOf($kvmDiskPhases[$relativePath], [StringComparison]::Ordinal)
            Assert-True ($seedPhase -ge 0 -and $diskPhase -gt $seedPhase) "$relativePath must preserve the prior disk until the seed preflight succeeds"
        }
    }
}

Describe 'Hyper-V Ubuntu release wrappers' {
    It 'preserves release defaults and unbound overrides in <Workflow> for Ubuntu <Release>' -TestCases @(
        @{ Release = '24'; Workflow = 'New-VM' }, @{ Release = '26'; Workflow = 'New-VM' },
        @{ Release = '24'; Workflow = 'Get-Image' }, @{ Release = '26'; Workflow = 'Get-Image' }
    ) {
        param($Release, $Workflow)
        $run = Invoke-UbuntuWrapperFixture -Release $Release -Workflow $Workflow
        $run.ExitCode | Should -Be 0
        $run.Arguments.Release | Should -BeExactly $Release
        $run.Arguments.GuestScriptRoot | Should -BeExactly $run.GuestScriptRoot
        if ($Workflow -eq 'New-VM') {
            $run.Arguments.Username | Should -BeExactly "yuuser$Release"
            foreach ($name in 'CachingProxyServiceUrl', 'Hostname', 'MemoryStartupBytes', 'Cores', 'ExposeVirtualizationExtensions') {
                $run.Arguments.ContainsKey($name) | Should -BeFalse
            }
        } else {
            $run.Arguments.ContainsKey('daily') | Should -BeFalse
            $key = if ($Release -eq '24') { 'host.operator_2542864c23790bce' } else { 'host.operator_ea494ffdd86805ef' }
            $run.Arguments.EnvironmentErrorKey | Should -BeExactly $key
        }
    }

    It 'preserves bound values including empty proxy and false switches in <Workflow> for Ubuntu <Release>' -TestCases @(
        @{ Release = '24'; Workflow = 'New-VM' }, @{ Release = '26'; Workflow = 'New-VM' },
        @{ Release = '24'; Workflow = 'Get-Image' }, @{ Release = '26'; Workflow = 'Get-Image' }
    ) {
        param($Release, $Workflow)
        $invocation = if ($Workflow -eq 'New-VM') {
            '-VMName test-override -Username operator -Hostname alternate-host -CachingProxyServiceUrl '''' -MemoryStartupBytes 4GB -Cores 3 -ExposeVirtualizationExtensions false'
        } else { '-daily:$false' }
        $run = Invoke-UbuntuWrapperFixture -Release $Release -Workflow $Workflow -Invocation $invocation
        $run.ExitCode | Should -Be 0
        if ($Workflow -eq 'New-VM') {
            $run.Arguments.VMName | Should -BeExactly 'test-override'
            $run.Arguments.Username | Should -BeExactly 'operator'
            $run.Arguments.Hostname | Should -BeExactly 'alternate-host'
            $run.Arguments.ContainsKey('CachingProxyServiceUrl') | Should -BeTrue
            $run.Arguments.CachingProxyServiceUrl | Should -BeExactly ''
            $run.Arguments.MemoryStartupBytes | Should -BeExactly '4GB'
            $run.Arguments.Cores | Should -BeExactly '3'
            $run.Arguments.ExposeVirtualizationExtensions | Should -BeExactly 'false'
        } else {
            $run.Arguments.ContainsKey('daily') | Should -BeTrue
            $run.Arguments.daily | Should -BeFalse
        }
    }

    It 'propagates shared workflow failure in <Workflow> for Ubuntu <Release>' -TestCases @(
        @{ Release = '24'; Workflow = 'New-VM' }, @{ Release = '26'; Workflow = 'New-VM' },
        @{ Release = '24'; Workflow = 'Get-Image' }, @{ Release = '26'; Workflow = 'Get-Image' }
    ) {
        param($Release, $Workflow)
        (Invoke-UbuntuWrapperFixture -Release $Release -Workflow $Workflow -ExitCode 19).ExitCode | Should -Be 19
    }

    It 'retains Ubuntu <Release> processor cap and MAC workaround policy' -TestCases @(
        @{ Release = '24'; MaximumCores = 2; SpoofCalls = 0 },
        @{ Release = '26'; MaximumCores = 1; SpoofCalls = 1 }
    ) {
        param($Release, $MaximumCores, $SpoofCalls)
        $ast = Get-ProvisionAst -Path (Join-Path $script:RepoRoot 'host/windows.hyper-v/modules/New-UbuntuServerVM.ps1')
        $policies = @($ast.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.IfStatementAst] -and
                $_.Clauses[0].Item1.Extent.Text -eq "`$Release -eq '26'"
            })
        $policies.Count | Should -Be 2
        $body = @'
param([string]$Release)
$vmCores = 8
$script:SpoofCalls = 0
$VMName = 'test-release-policy'
function Limit-HyperVLinuxGuestCoreCount {
    param([int]$RequestedCores, [int]$MaximumCores = 2)
    [math]::Min($RequestedCores, $MaximumCores)
}
function Set-VMNetworkAdapter {
    param([string]$VMName, [string]$MacAddressSpoofing)
    if ($VMName -ne 'test-release-policy' -or $MacAddressSpoofing -ne 'On') { throw 'Wrong network policy' }
    $script:SpoofCalls++
}
'@
        $body += "`n" + (($policies | ForEach-Object { $_.Extent.Text }) -join "`n")
        $body += "`n@{ Cores = `$vmCores; SpoofCalls = `$script:SpoofCalls } | ConvertTo-Json -Compress"
        $run = Invoke-ProvisionFixture -Body $body -Argument @('-Release', $Release)
        $run.ExitCode | Should -Be 0
        $actual = $run.Output | ConvertFrom-Json
        $actual.Cores | Should -Be $MaximumCores
        $actual.SpoofCalls | Should -Be $SpoofCalls
    }

    It 'retains Ubuntu <Release> live ISO selection and daily preference' -TestCases @(
        @{ Release = '24'; Codename = 'noble' }, @{ Release = '26'; Codename = 'resolute' }
    ) {
        param($Release, $Codename)
        $ast = Get-ProvisionAst -Path (Join-Path $script:RepoRoot 'host/windows.hyper-v/modules/Get-UbuntuServerImage.ps1')
        $download = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
        $download.Count | Should -Be 1
        $body = @'
param([string]$Release)
$hostArch = 'arm64'
$downloadDir = 'test images'
$daily = $true
function Save-UbuntuServerImage {
    param($ReleaseCodename, $Arch, $DownloadDir, $BaseImageName, [switch]$PreferDaily, [switch]$EmitProxyDiagnosticOnFailure)
    $captured = @{} + $PSBoundParameters
    $captured.PreferDaily = [bool]$PreferDaily
    $captured.EmitProxyDiagnosticOnFailure = [bool]$EmitProxyDiagnosticOnFailure
    $captured | ConvertTo-Json -Compress
}
'@
        $body += "`n" + $download[0].Extent.Text
        $run = Invoke-ProvisionFixture -Body $body -Argument @('-Release', $Release)
        $run.ExitCode | Should -Be 0
        $actual = $run.Output | ConvertFrom-Json
        $actual.ReleaseCodename | Should -BeExactly $Codename
        $actual.BaseImageName | Should -BeExactly "host.windows.hyper-v.guest.ubuntu.server.$Release"
        $actual.Arch | Should -BeExactly 'arm64'
        $actual.DownloadDir | Should -BeExactly 'test images'
        $actual.PreferDaily | Should -BeTrue
        $actual.EmitProxyDiagnosticOnFailure | Should -BeTrue
    }
}

Describe 'Amazon Linux origin-listing boundary' {
    It 'makes every listing request terminating and rejects a missing qcow2 link explicitly' {
        $imageScripts = @(
            'host/windows.hyper-v/guest.amazon.linux.2023/Get-Image.ps1',
            'host/macos.utm/guest.amazon.linux.2023/Get-Image.ps1',
            'host/ubuntu.kvm/guest.amazon.linux.2023/Get-Image.ps1'
        )
        foreach ($relativePath in $imageScripts) {
            $text = Get-EffectiveGuestBuilderSource -Path (Join-Path $script:RepoRoot $relativePath)
            Assert-Match '\$html\s*=\s*Invoke-WebRequest\s+-Uri\s+\$sourceUrl\s+-ErrorAction\s+Stop\b' $text "$relativePath must terminate when its origin listing request fails"
        }

        foreach ($hostName in @('macos.utm', 'ubuntu.kvm')) {
            $relativePath = "host/$hostName/guest.amazon.linux.2023/Get-Image.ps1"
            $text = Get-EffectiveGuestBuilderSource -Path (Join-Path $script:RepoRoot $relativePath)
            $ast = Get-ProvisionAst (Join-Path $script:RepoRoot $relativePath)
            $missing = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -match '^\s*-not\s+\$qcow2Link\s*$'
                }, $true)
            Assert-NotNull $missing "$relativePath must reject an absent qcow2 link"
            $body = '$qcow2Link = $null; $sourceUrl = "fixture://origin/"' + "`n" + $missing.Extent.Text + "`nWrite-Output 'AFTER_ORIGIN_GATE'"
            $result = Invoke-ProvisionFixture $body
            Assert-True ($result.ExitCode -ne 0) "$relativePath must fail before composing an absent qcow2 URL"
            Assert-False ($result.Output.Contains('AFTER_ORIGIN_GATE')) "$relativePath continued after an absent qcow2 link"
            Assert-True ($result.Output.Contains('No .qcow2 listed at fixture://origin/')) "$relativePath must name the missing image and origin"
        }
    }
}

Describe 'Download-agent artifact pattern' {
    BeforeAll {
        # One record per -ExpectedFilenamePattern argument that a Get-Image script
        # hands a download-agent call: the argument's AST and, when that is a
        # variable, the assignment that precedes the call in the script ($null
        # when there is none). An unassigned variable binds as an empty pattern,
        # which the agent reads as "no expectation" and accepts any artifact.
        function Get-AgentPatternArgument {
            param([string]$Path)
            $ast = Get-ProvisionAst $Path
            $calls = $ast.FindAll({ param($n)
                    $n -is [Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -in @('Invoke-DownloadAgentFirst', 'Request-DownloadAgentImage')
                }, $true)
            foreach ($call in $calls) {
                $elements = $call.CommandElements
                for ($i = 0; $i -lt $elements.Count; $i++) {
                    $parameter = $elements[$i]
                    if ($parameter -isnot [Management.Automation.Language.CommandParameterAst] -or
                        $parameter.ParameterName -ne 'ExpectedFilenamePattern') { continue }
                    $value = if ($parameter.Argument) { $parameter.Argument } else { $elements[$i + 1] }
                    $assignment = $null
                    if ($value -is [Management.Automation.Language.VariableExpressionAst]) {
                        $name = $value.VariablePath.UserPath
                        $assignment = $ast.FindAll({ param($n)
                                $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                                $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                                $n.Left.VariablePath.UserPath -eq $name -and
                                $n.Extent.StartOffset -lt $call.Extent.StartOffset
                            }, $true) | Select-Object -First 1
                    }
                    [pscustomobject]@{ Command = $call.GetCommandName(); Value = $value; Assignment = $assignment }
                }
            }
        }
    }

    It 'assigns the variable a Get-Image script hands the agent as its artifact pattern before the call' {
        $checked = 0
        foreach ($file in Get-ChildItem (Join-Path $script:RepoRoot 'host/*/guest.*/Get-Image.ps1')) {
            foreach ($argument in @(Get-AgentPatternArgument $file.FullName)) {
                $checked++
                if ($argument.Value -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
                $name = $argument.Value.VariablePath.UserPath
                Assert-NotNull $argument.Assignment "$($file.FullName) hands $($argument.Command) `$$name but assigns it nowhere before the call, which switches the agent's artifact check off"
            }
        }
        Assert-True ($checked -ge 6) "each Amazon Linux 2023 and Windows 11 Get-Image script must state an artifact pattern; found $checked"
    }

    It 'gives every Amazon Linux 2023 host a pattern that accepts only the artifact it stages' {
        $cases = @(
            @{ Script = 'host/macos.utm/guest.amazon.linux.2023/Get-Image.ps1';       Extension = 'qcow2'; Refused = @('zip', 'vhdx') }
            @{ Script = 'host/ubuntu.kvm/guest.amazon.linux.2023/Get-Image.ps1';      Extension = 'qcow2'; Refused = @('zip', 'vhdx') }
            @{ Script = 'host/windows.hyper-v/guest.amazon.linux.2023/Get-Image.ps1'; Extension = 'zip';   Refused = @('qcow2') }
            @{ Script = 'host/windows.hyper-v/guest.amazon.linux.2023/Get-Image.ps1'; Extension = 'qcow2'; Refused = @('zip') }
        )
        foreach ($case in $cases) {
            $argument = @(Get-AgentPatternArgument (Join-Path $script:RepoRoot $case.Script) |
                    Where-Object Command -eq 'Invoke-DownloadAgentFirst')
            Assert-True ($argument.Count -eq 1) "$($case.Script) must hand Invoke-DownloadAgentFirst exactly one artifact pattern"
            $expression = if ($argument[0].Assignment) { $argument[0].Assignment.Right.Extent.Text } else { $argument[0].Value.Extent.Text }
            # The Hyper-V pattern is built from the extension its architecture
            # branch picks; the macOS and KVM patterns ignore the parameter.
            $pattern = & ([scriptblock]::Create('param($downloadExtension)' + "`n" + $expression)) $case.Extension
            Assert-True (-not [string]::IsNullOrWhiteSpace($pattern)) "$($case.Script) must hand the agent a non-empty pattern; an empty one accepts any artifact"
            $stem = 'al2023-kvm-2023.9.20260101.0-kernel-6.1-x86_64'
            Assert-True ("$stem.$($case.Extension)" -match $pattern) "$($case.Script) must accept a .$($case.Extension) artifact (pattern '$pattern')"
            Assert-False ("$stem.$($case.Extension).sha256" -match $pattern) "$($case.Script) must refuse the checksum sidecar (pattern '$pattern')"
            foreach ($other in $case.Refused) {
                Assert-False ("$stem.$other" -match $pattern) "$($case.Script) must refuse a .$other artifact (pattern '$pattern')"
            }
        }
    }
}

Describe 'Service VM disk-capacity boundary' {
    It 'fails the child build before any later phase when expansion fails on every host' {
        Assert-True ($script:ServiceBuilders.Count -eq 12) 'all four service families on all three hosts must be covered'
        foreach ($builder in $script:ServiceBuilders) {
            $ast = Get-ProvisionAst $builder.FullName
            $call = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Expand-ExtensionVmDisk' }, $true)
            Assert-NotNull $call "missing disk-capacity gate: $($builder.FullName)"
            $gate = $call
            while ($gate -and $gate -isnot [System.Management.Automation.Language.IfStatementAst]) { $gate = $gate.Parent }
            Assert-NotNull $gate "disk resize is not guarded by an if: $($builder.FullName)"
            $body = @'
$ErrorActionPreference = 'Continue'
$diskImg = $DiskImage = $vhdxFile = 'fixture-disk'
function Expand-ExtensionVmDisk { param($Path, $SizeBytes, $Format) return $false }
'@ + "`n" + $gate.Extent.Text + "`nWrite-Output 'AFTER_DISK_RESIZE'`nexit 0"
            $result = Invoke-ProvisionFixture $body
            Assert-True ($result.ExitCode -ne 0) "$($builder.FullName) must report a failed child build"
            Assert-False ($result.Output.Contains('AFTER_DISK_RESIZE')) "$($builder.FullName) continued after failed expansion"
            Assert-True ($result.Output.Contains('Could not resize')) "$($builder.FullName) must identify disk expansion as the failure"
        }
    }

    It 'continues after successful expansion on every host' {
        foreach ($builder in $script:ServiceBuilders) {
            $ast = Get-ProvisionAst $builder.FullName
            $gate = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Expand-ExtensionVmDisk' }, $true)
            while ($gate -and $gate -isnot [System.Management.Automation.Language.IfStatementAst]) { $gate = $gate.Parent }
            Assert-NotNull $gate "disk resize is not guarded by an if: $($builder.FullName)"
            $body = @'
$ErrorActionPreference = 'Stop'
$diskImg = $DiskImage = $vhdxFile = 'fixture-disk'
function Expand-ExtensionVmDisk { param($Path, $SizeBytes, $Format) return $true }
'@ + "`n" + $gate.Extent.Text + "`nWrite-Output 'AFTER_DISK_RESIZE'`nexit 0"
            $result = Invoke-ProvisionFixture $body
            Assert-True ($result.ExitCode -eq 0) "$($builder.FullName): $($result.Output)"
            Assert-True ($result.Output.Contains('AFTER_DISK_RESIZE')) "$($builder.FullName) did not continue after successful expansion"
        }
    }
}

Describe 'KVM Windows media adoption' {
    It 'rejects ARM-labeled media and accepts x64 or unlabeled media without changing their bytes' {
        $path = Join-Path $script:RepoRoot 'host/ubuntu.kvm/guest.windows.11/Get-Image.ps1'
        $ast = Get-ProvisionAst $path
        $candidate = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$candidate' }, $true)
        $adoption = $candidate
        while ($adoption -isnot [System.Management.Automation.Language.IfStatementAst]) { $adoption = $adoption.Parent }
        foreach ($case in @(
            @{ Name = 'Win11_English_Arm64.iso'; Adopt = $false },
            @{ Name = 'Win11_English_ARM64.iso'; Adopt = $false },
            @{ Name = 'Win11_English_x64.iso'; Adopt = $true },
            @{ Name = 'Win11_custom.iso'; Adopt = $true }
        )) {
            $downloadDir = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $downloadDir
            $baseImageName = 'host.ubuntu.kvm.guest.windows.11'
            $winIso = Join-Path $downloadDir "$baseImageName.iso"
            $original = Join-Path $downloadDir $case.Name
            Set-Content -LiteralPath $original -Value 'fixture ISO bytes' -NoNewline
            & ([scriptblock]::Create($adoption.Extent.Text)) | Out-Null
            Assert-True ((Test-Path -LiteralPath $winIso) -eq $case.Adopt) "wrong architecture decision for $($case.Name)"
            Assert-True ((Test-Path -LiteralPath $original) -ne $case.Adopt) "wrong adoption result for $($case.Name)"
            $retained = if ($case.Adopt) { $winIso } else { $original }
            Assert-StringEqual 'fixture ISO bytes' (Get-Content -LiteralPath $retained -Raw)
        }
    }
}

Describe 'UTM public Stop-VM contract' {
    It 'uses graceful stopping by default and kill stopping with Force' {
        $modulePath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        foreach ($mode in @('graceful', 'force', 'direct-force')) {
            $r = Invoke-ProvisionFixture $script:UtmFixture @($modulePath, $mode, '0')
            Assert-True ($r.ExitCode -eq 0) $r.Output
            $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            Assert-True $data.Result
            Assert-True ($data.Calls.Count -eq 1) $r.Output
            Assert-True ($data.WatchdogStops -eq 1) "$mode must stop the dialog watchdog once"
            $expected = if ($mode -eq 'graceful') { 'stop test-provision' } else { 'stop test-provision --kill' }
            Assert-StringEqual $expected $data.Calls[0]
        }
    }

    It 'propagates native failure from both stop modes' {
        $modulePath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        foreach ($mode in @('graceful', 'force', 'direct-force')) {
            $r = Invoke-ProvisionFixture $script:UtmFixture @($modulePath, $mode, '9')
            $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            Assert-False $data.Result $r.Output
            Assert-True ($data.Calls.Count -eq 1) $r.Output
            Assert-True ($data.WatchdogStops -eq 1) "$mode must stop the dialog watchdog even when utmctl fails"
        }
    }

    It 'does not invoke utmctl when Force is previewed with WhatIf' {
        $modulePath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        foreach ($mode in @('whatif', 'direct-whatif')) {
            $r = Invoke-ProvisionFixture $script:UtmFixture @($modulePath, $mode, '0')
            Assert-True ($r.ExitCode -eq 0) $r.Output
            $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            Assert-False $data.Result
            Assert-True ($data.Calls.Count -eq 0) $r.Output
            Assert-True ($data.WatchdogStops -eq 0) "$mode must leave the dialog watchdog running"
        }
    }
}

Describe 'KVM public Remove-VM absence proof' {
    It 'preserves storage after successful undefine when the final inventory is <Mode>' -TestCases @(
        @{ Mode = 'undefined-present' }, @{ Mode = 'undefined-inventory-failed' }
    ) {
        param($Mode)
        $modulePath = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
        $scratchRoot = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
        $run = Invoke-ProvisionFixture $script:KvmFixture @($modulePath, $Mode, $scratchRoot)
        $run.ExitCode | Should -Be 0
        $data = ($run.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        $data.Result | Should -BeFalse
        $data.DiskExists | Should -BeTrue
    }

    It 'removes storage after successful undefine only when the final inventory confirms absence' {
        $modulePath = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
        $scratchRoot = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
        $run = Invoke-ProvisionFixture $script:KvmFixture @($modulePath, 'undefined-absent', $scratchRoot)
        $run.ExitCode | Should -Be 0
        $data = ($run.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        $data.Result | Should -BeTrue
        $data.DiskExists | Should -BeFalse
    }

    It 'retains guest storage when failed undefine is followed by an unavailable inventory or a surviving domain' {
        $modulePath = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
        foreach ($mode in @('inventory-failed', 'present')) {
            $scratchRoot = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
            $r = Invoke-ProvisionFixture $script:KvmFixture @($modulePath, $mode, $scratchRoot)
            Assert-True ($r.ExitCode -eq 0) $r.Output
            $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            Assert-False $data.Result $r.Output
            Assert-True $data.DiskExists 'failed inventory or a surviving VM cannot authorize disk deletion'
        }
    }

    It 'removes leftover storage when inventory confirms the domain is already absent' {
        $modulePath = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
        $scratchRoot = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
        $r = Invoke-ProvisionFixture $script:KvmFixture @($modulePath, 'absent', $scratchRoot)
        Assert-True ($r.ExitCode -eq 0) $r.Output
        $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        Assert-True $data.Result $r.Output
        Assert-False $data.DiskExists
    }
}

Describe 'UTM Ubuntu cache selection' {
    It 'refuses implicit direct access for <State> with an <Probe> cache' -TestCases @(
        @{ State = 'running'; Probe = 'unreachable' },
        @{ State = 'running'; Probe = 'exception' },
        @{ State = 'unknown'; Probe = 'unreachable' },
        @{ State = 'unknown'; Probe = 'exception' },
        @{ State = ''; Probe = 'unreachable' },
        @{ State = 'started'; Probe = 'unreachable' },
        @{ State = 'exception'; Probe = 'unreachable' }
    ) {
        param($State, $Probe)
        $run = Invoke-UtmCacheFixture -State $State -Probe $Probe
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Not -Match 'AFTER_CACHE_GATE'
        $run.Calls[0] | Should -BeExactly 'state'
    }

    It 'uses a verified endpoint despite <State> provider status' -TestCases @(
        @{ State = 'running' }, @{ State = 'unknown' }, @{ State = 'stopped' }, @{ State = 'absent' }
    ) {
        param($State)
        $run = Invoke-UtmCacheFixture -State $State -Probe 'reachable'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'AFTER_CACHE_GATE'
        $data = ($run.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        $data.Url | Should -BeExactly 'http://192.0.2.7:3128'
        ($run.Calls -join ',') | Should -BeExactly 'state,proxy'
    }

    It 'permits direct access only when the cache is recognized <State>' -TestCases @(
        @{ State = 'stopped' }, @{ State = 'absent' }
    ) {
        param($State)
        $run = Invoke-UtmCacheFixture -State $State
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'AFTER_CACHE_GATE'
        $data = ($run.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        $data.Url | Should -BeExactly ''
    }

    It 'bypasses provider discovery for an explicitly <Binding> proxy override' -TestCases @(
        @{ Binding = 'empty'; Expected = '' }, @{ Binding = 'url'; Expected = 'http://192.0.2.8:3128' }
    ) {
        param($Binding, $Expected)
        $run = Invoke-UtmCacheFixture -State 'exception' -Probe 'exception' -Binding $Binding
        $run.ExitCode | Should -Be 0
        @($run.Calls).Count | Should -Be 0
        $data = ($run.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        $data.Url | Should -BeExactly $Expected
    }
}

Describe 'UTM replacement power-off and registration boundary' {
    It 'preserves bundle and registration when the final power-off check is <PowerOff>' -TestCases @(
        @{ PowerOff = 'unknown' }, @{ PowerOff = 'locked' }
    ) {
        param($PowerOff)
        $run = Invoke-UtmRemovalFixture -PowerOff $PowerOff
        $run.Result | Should -BeFalse
        ($run.Order -join ',') | Should -BeExactly 'stop,poweroff'
        $run.DiskExists | Should -BeTrue
        $run.Bytes | Should -BeExactly 'retained guest bytes'
    }

    It 'uses the confirmed final <PowerOff> state after a <Stop> stop outcome' -TestCases @(
        @{ Stop = 'success'; PowerOff = 'confirmed' },
        @{ Stop = 'failed'; PowerOff = 'confirmed' },
        @{ Stop = 'unknown'; PowerOff = 'confirmed' },
        @{ Stop = 'failed'; PowerOff = 'absent' }
    ) {
        param($Stop, $PowerOff)
        $run = Invoke-UtmRemovalFixture -Stop $Stop -PowerOff $PowerOff
        $run.Result | Should -BeTrue
        ($run.Order -join ',') | Should -BeExactly 'stop,poweroff,unregister,bundle'
        $run.DiskExists | Should -BeFalse
    }

    It 'retains the complete bundle when registration could not be removed' {
        $run = Invoke-UtmRemovalFixture -Registration 'registered'
        $run.Result | Should -BeFalse
        ($run.Order -join ',') | Should -BeExactly 'stop,poweroff,unregister'
        $run.DiskExists | Should -BeTrue
        $run.Bytes | Should -BeExactly 'retained guest bytes'
    }

    It 'reports failed filesystem removal without accepting a partial replacement' {
        $run = Invoke-UtmRemovalFixture -Registration 'files-failed'
        $run.Result | Should -BeFalse
        ($run.Order -join ',') | Should -BeExactly 'stop,poweroff,unregister,bundle'
        $run.DiskExists | Should -BeTrue
    }

    It 'does not stop, unregister or delete a previewed VM' {
        $run = Invoke-UtmRemovalFixture -Preview
        $run.Result | Should -BeFalse
        @($run.Order).Count | Should -Be 0
        $run.DiskExists | Should -BeTrue
    }

    It 'stops <Guest> before any replacement writes when removal refuses' -TestCases @(
        @{ Guest = 'guest.amazon.linux.2023' }, @{ Guest = 'guest.caching-proxy-service' },
        @{ Guest = 'guest.download-agent-service' }, @{ Guest = 'guest.macos.26' },
        @{ Guest = 'guest.pool-control-service' }, @{ Guest = 'guest.stash-service' },
        @{ Guest = 'guest.windows.11' }, @{ Guest = 'modules' }
    ) {
        param($Guest)
        $leaf = if ($Guest -eq 'modules') { 'New-UbuntuServerVM.ps1' } else { 'New-VM.ps1' }
        $path = Join-Path $script:RepoRoot "host/macos.utm/$Guest/$leaf"
        $ast = Get-ProvisionAst $path
        $call = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Remove-UtmTestVM'
            }, $true)
        $call | Should -Not -BeNullOrEmpty
        $gate = $call
        while ($gate -and $gate -isnot [Management.Automation.Language.IfStatementAst]) { $gate = $gate.Parent }
        $gate | Should -Not -BeNullOrEmpty
        $body = @'
$ErrorActionPreference = 'Continue'
$VMName = 'test-replacement'
$UtmDir = 'private-fixture-bundle'
function Remove-UtmTestVM {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$VMName)
    if ($VMName -ne 'test-replacement') { throw 'Wrong replacement VM' }
    return $false
}
'@
        $body += "`n" + $gate.Extent.Text + "`n'AFTER_REPLACEMENT_GATE'; exit 0"
        $run = Invoke-ProvisionFixture -Body $body
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Not -Match 'AFTER_REPLACEMENT_GATE'
    }
}
