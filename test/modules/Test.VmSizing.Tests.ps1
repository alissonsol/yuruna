<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42a296aa-3108-4ad0-928d-3bf246b2d537
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test vm sizing memory cores new-vm cascade pester
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
    Guards on the VM-sizing contract: a sequence's `variables.memoryStartupBytes`
    and `variables.cores` must reach the per-guest New-VM.ps1, exactly like
    `variables.username` / `variables.hostname` do. The nested-virtualization
    request (`variables.exposeVirtualizationExtensions`) travels the same
    cascade and is guarded here too.
.DESCRIPTION
    The value crosses the same files (planner -> runner/Debug-TestSequence -> the
    Invoke-PerGuestNewVm dispatcher -> the per-guest New-VM.ps1), and the
    dispatcher forwards -MemoryStartupBytes/-Cores only to scripts that DECLARE
    them, dropping them on the Verbose stream otherwise. A guest script that
    forgets the parameter therefore fails silently: the VM builds, at the wrong
    size. These guards make that omission a test failure.

    ConvertTo-MemoryStartupBytes is exercised functionally, and so is the
    dispatcher's declare-or-drop forwarding: the real Invoke-PerGuestNewVm runs
    against a throwaway guest script that only echoes what it was handed.
    Everything else is source-text only. No host driver is imported and no VM
    is touched. Throw-based assertions so the file runs under Pester 5.x.
#>

BeforeDiscovery {
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The guest scripts wired for sizing overrides: ubuntu.server.24 on every host.
$guestPaths = @(
    'host/windows.hyper-v/guest.ubuntu.server.24/New-VM.ps1',
    'host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1',
    'host/macos.utm/guest.ubuntu.server.24/New-VM.ps1'
) | ForEach-Object { Join-Path $repoRoot $_ }
$script:guestCase = @($guestPaths | ForEach-Object { @{ name = (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $_))); path = $_ } })

$hostContract = @(
    'host/windows.hyper-v/modules/Yuruna.Host.psm1',
    'host/ubuntu.kvm/modules/Yuruna.Host.psm1',
    'host/macos.utm/modules/Yuruna.Host.psm1'
) | ForEach-Object { Join-Path $repoRoot $_ }
$script:hostCase = @($hostContract | ForEach-Object { @{ name = (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $_))); path = $_ } })

# The guest scripts wired for the nested-virtualization request: Hyper-V only
# (KVM nested virt is a host-level kernel-module setting; UTM has no per-VM
# knob), across every Hyper-V guest OS that can host a hypervisor of its own.
$hyperVGuestPaths = @(
    'host/windows.hyper-v/guest.windows.11/New-VM.ps1',
    'host/windows.hyper-v/guest.ubuntu.server.24/New-VM.ps1',
    'host/windows.hyper-v/guest.ubuntu.server.26/New-VM.ps1'
) | ForEach-Object { Join-Path $repoRoot $_ }
$script:hyperVGuestCase = @($hyperVGuestPaths | ForEach-Object { @{ name = (Split-Path -Leaf (Split-Path -Parent $_)); path = $_ } })

if ($script:guestCase.Count -ne 3 -or $script:hostCase.Count -ne 3 -or $script:hyperVGuestCase.Count -ne 3) { throw 'VM-sizing discovery must include every wired host and guest fixture.' }
}

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:plannerSrc   = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.SequencePlanner.psm1')
$script:runnerSrc    = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.SequenceRunner.psm1')
$script:innerSrc     = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.RunnerInnerLoop.psm1')
$script:seqEntrySrc  = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/Debug-TestSequence.ps1')

Import-Module (Join-Path $repoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking

# One run of the real dispatcher against a throwaway guest script that declares
# -VMName plus $Declare, echoes each of those as "<Name>=<value>", and then
# echoes whatever it was handed without declaring. Returns the child's lines,
# the dispatcher's Verbose lines and its result. The script only echoes, so no
# hypervisor is involved.
function Invoke-DispatcherFixture {
    param([string[]]$Declare = @(), [hashtable]$Bind = @{})
    $root = New-YurunaTestTempDir -Prefix 'yuruna-vm-sizing'
    try {
        $guestDir = Join-Path $root (Join-Path 'fixture.host' 'guest.fixture')
        $null = New-Item -ItemType Directory -Path $guestDir -Force
        $declared = @('[string]$VMName') + @($Declare | ForEach-Object { "[string]`$$_ = ''" })
        $lines = @("param($($declared -join ', '))") +
            @($Declare | ForEach-Object { "Write-Output ""$_=`$$_""" }) +
            @('Write-Output "undeclared=$($args -join '' '')"')
        Set-Content -LiteralPath (Join-Path $guestDir 'New-VM.ps1') -Value $lines
        $relayed = $null
        $emitted = @(Invoke-PerGuestNewVm -HostSubdir 'fixture.host' -GuestKey 'guest.fixture' -RepoRoot $root -VMName 'vm-fixture' @Bind `
                -Confirm:$false -Verbose -InformationVariable relayed 4>&1)
        return @{
            Result  = @($emitted | Where-Object { $_ -is [hashtable] })[0]
            Verbose = @($emitted | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
            Child   = @($relayed | ForEach-Object { [string]$_.MessageData })
        }
    } finally { Remove-YurunaTestTempDir $root }
}

}

Describe 'vm-sizing -- ConvertTo-MemoryStartupBytes normalizes memory sizes' {
    BeforeAll { Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force }

    It 'returns 0 for empty / whitespace (unset sentinel)' {
        Assert-True ((ConvertTo-MemoryStartupBytes '')   -eq 0)
        Assert-True ((ConvertTo-MemoryStartupBytes '  ') -eq 0)
    }
    It 'parses a binary GB suffix to match the PowerShell literal' {
        Assert-True ((ConvertTo-MemoryStartupBytes '32GB') -eq 32GB) '32GB must equal the 32GB literal to the byte'
    }
    It 'treats MB, GB, and raw bytes consistently' {
        Assert-True ((ConvertTo-MemoryStartupBytes '32768MB') -eq (ConvertTo-MemoryStartupBytes '32GB'))
        Assert-True ((ConvertTo-MemoryStartupBytes '8192')    -eq 8192) 'a bare number is bytes'
    }
    It 'throws on a non-numeric, bad-suffix, or non-positive value' {
        foreach ($bad in @('abc', '32XB', '0', '-5')) {
            $threw = $false
            try { ConvertTo-MemoryStartupBytes $bad } catch { $threw = $true }
            Assert-True $threw "ConvertTo-MemoryStartupBytes '$bad' must throw, not silently default"
        }
    }
}

Describe 'vm-sizing -- guest New-VM.ps1 declares and applies the overrides' {
    It 'finds the wired guest scripts (fixture sanity)' -TestCases @(@{ guestPaths = [string[]]@($script:guestCase.path) }) {
        param($guestPaths)
        Assert-True ($guestPaths.Count -eq 3) "expected 3 wired guest scripts, found $($guestPaths.Count)"
        foreach ($p in $guestPaths) { Assert-True (Test-Path -LiteralPath $p) "missing guest script: $p" }
    }
    It 'declares -MemoryStartupBytes so the dispatcher forwards it: <name>' -TestCases $script:guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$MemoryStartupBytes\s*=\s*''''') `
            "$name has no [string]`$MemoryStartupBytes = '' parameter; Invoke-PerGuestNewVm would drop the cascade to Verbose"
    }
    It 'declares -Cores so the dispatcher forwards it: <name>' -TestCases $script:guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$Cores\s*=\s*''''') `
            "$name has no [string]`$Cores = '' parameter"
    }
    It 'resolves memory through ConvertTo-MemoryStartupBytes: <name>' -TestCases $script:guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        # A guest script that delegates to its host's shared Ubuntu builder applies the sizing there.
        $shared = Join-Path (Split-Path -Parent (Split-Path -Parent $path)) 'modules/New-UbuntuServerVM.ps1'
        if ($src -match 'New-UbuntuServerVM\.ps1' -and (Test-Path -LiteralPath $shared)) { $src = Get-Content -Raw -LiteralPath $shared }
        Assert-True ($src -match 'ConvertTo-MemoryStartupBytes\s+\$MemoryStartupBytes') `
            "$name must normalize `$MemoryStartupBytes via the shared helper"
    }
    It 'guards the cores override on a non-empty -Cores: <name>' -TestCases $script:guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        $shared = Join-Path (Split-Path -Parent (Split-Path -Parent $path)) 'modules/New-UbuntuServerVM.ps1'
        if ($src -match 'New-UbuntuServerVM\.ps1' -and (Test-Path -LiteralPath $shared)) { $src = Get-Content -Raw -LiteralPath $shared }
        Assert-True ($src -match [regex]::Escape('if ($Cores) {')) `
            "$name must only override vCPU count when -Cores was actually passed"
        Assert-True ($src -match [regex]::Escape('$vmCores = $coresInt')) `
            "$name must apply the parsed core count to `$vmCores"
    }
}

Describe 'vm-sizing -- the dispatcher forwards under the declare-or-drop rule' {
    BeforeAll {
        $sizing = @{ MemoryStartupBytes = '4GB'; Cores = '2' }
        $script:sizingDeclared   = Invoke-DispatcherFixture -Declare @('MemoryStartupBytes', 'Cores') -Bind $sizing
        $script:sizingUndeclared = Invoke-DispatcherFixture -Bind $sizing
    }
    It 'probes the target script for -MemoryStartupBytes and -Cores' {
        # A guest script that declares neither must not be handed them, and the
        # drop has to be named on Verbose: it is the only trace of a VM built
        # at the default size.
        $run = $script:sizingUndeclared
        Assert-True $run.Result.success "a guest script that declares neither sizing parameter must still run: $($run.Result.errorMessage)"
        Assert-True ($run.Child -ccontains 'undeclared=') `
            "Invoke-PerGuestNewVm must probe for -MemoryStartupBytes and -Cores before forwarding; the guest script was handed: $($run.Child -join ' | ')"
        Assert-True (@($run.Verbose | Where-Object { $_ -cmatch "^Cascaded -MemoryStartupBytes '4GB' NOT forwarded: .* does not declare a -MemoryStartupBytes parameter\.$" }).Count -eq 1) `
            'a dropped -MemoryStartupBytes must be reported on the Verbose stream'
        Assert-True (@($run.Verbose | Where-Object { $_ -cmatch "^Cascaded -Cores '2' NOT forwarded: .* does not declare a -Cores parameter\.$" }).Count -eq 1) `
            'a dropped -Cores must be reported on the Verbose stream'
    }
    It 'appends -MemoryStartupBytes and -Cores to the child argument list' {
        $run = $script:sizingDeclared
        Assert-True $run.Result.success "the guest script that declares both sizing parameters must run: $($run.Result.errorMessage)"
        Assert-True ($run.Child -ccontains 'MemoryStartupBytes=4GB') `
            "a probed-and-present -MemoryStartupBytes must reach the child script; it reported: $($run.Child -join ' | ')"
        Assert-True ($run.Child -ccontains 'Cores=2') `
            "a probed-and-present -Cores must reach the child script; it reported: $($run.Child -join ' | ')"
    }
}

Describe 'vm-sizing -- host-contract New-VM wrappers declare the pass-through params' {
    It 'declares -MemoryStartupBytes and -Cores: <name>' -TestCases $script:hostCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$MemoryStartupBytes\b') `
            "$name New-VM wrapper must declare -MemoryStartupBytes so @PSBoundParameters carries it to the dispatcher"
        Assert-True ($src -match '(?m)^\s*\[string\]\$Cores\b') `
            "$name New-VM wrapper must declare -Cores"
    }
}

Describe 'vm-sizing -- the planner cascade surfaces the effective fields' {
    It 'Test.SequencePlanner emits effectiveMemoryStartupBytes and effectiveCores' {
        Assert-True ($script:plannerSrc -match 'effectiveMemoryStartupBytes') 'planner must extract memoryStartupBytes from the cascade'
        Assert-True ($script:plannerSrc -match 'effectiveCores') 'planner must extract cores from the cascade'
    }
    It 'Test.SequenceRunner returns them from Resolve-TestSequencePlan' {
        Assert-True ($script:runnerSrc -match 'effectiveMemoryStartupBytes') 'Resolve-TestSequencePlan must surface memoryStartupBytes'
        Assert-True ($script:runnerSrc -match 'effectiveCores') 'Resolve-TestSequencePlan must surface cores'
    }
    It 'both forward sites add MemoryStartupBytes/Cores to newVmArgs' {
        Assert-True ($script:seqEntrySrc -match [regex]::Escape('$newVmArgs.MemoryStartupBytes')) 'Debug-TestSequence must forward memory'
        Assert-True ($script:seqEntrySrc -match [regex]::Escape('$newVmArgs.Cores')) 'Debug-TestSequence must forward cores'
        Assert-True ($script:innerSrc -match [regex]::Escape('$newVmArgs.MemoryStartupBytes')) 'the runner must forward memory'
        Assert-True ($script:innerSrc -match [regex]::Escape('$newVmArgs.Cores')) 'the runner must forward cores'
    }
}

Describe 'nested-virt -- exposeVirtualizationExtensions travels the same cascade, off by default' {
    It 'finds the wired Hyper-V guest scripts (fixture sanity)' -TestCases @(@{ hyperVGuestPaths = [string[]]@($script:hyperVGuestCase.path) }) {
        param($hyperVGuestPaths)
        Assert-True ($hyperVGuestPaths.Count -eq 3) "expected 3 wired Hyper-V guest scripts, found $($hyperVGuestPaths.Count)"
        foreach ($p in $hyperVGuestPaths) { Assert-True (Test-Path -LiteralPath $p) "missing guest script: $p" }
    }
    It 'declares -ExposeVirtualizationExtensions defaulting to unset: <name>' -TestCases $script:hyperVGuestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$ExposeVirtualizationExtensions\s*=\s*''''') `
            "$name has no [string]`$ExposeVirtualizationExtensions = '' parameter; Invoke-PerGuestNewVm would drop the cascade to Verbose"
    }
    It 'never hardcodes -ExposeVirtualizationExtensions $true on Set-VMProcessor: <name>' -TestCases $script:hyperVGuestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        $shared = Join-Path (Split-Path -Parent (Split-Path -Parent $path)) 'modules/New-UbuntuServerVM.ps1'
        if ($src -match 'New-UbuntuServerVM\.ps1' -and (Test-Path -LiteralPath $shared)) { $src = Get-Content -Raw -LiteralPath $shared }
        Assert-True ($src -notmatch [regex]::Escape('-ExposeVirtualizationExtensions $true')) `
            "$name passes -ExposeVirtualizationExtensions `$true unconditionally; an ARM64 host then fails every VM start with 'this platform does not support nested virtualization'"
        Assert-True ($src -match [regex]::Escape('$vmProcessorArgs.ExposeVirtualizationExtensions')) `
            "$name must add ExposeVirtualizationExtensions to the Set-VMProcessor splat only when requested"
    }
    It 'the dispatcher probes and forwards -ExposeVirtualizationExtensions' {
        $request = @{ ExposeVirtualizationExtensions = 'true' }
        $undeclared = Invoke-DispatcherFixture -Bind $request
        Assert-True $undeclared.Result.success "a guest script that does not declare the parameter must still run: $($undeclared.Result.errorMessage)"
        Assert-True ($undeclared.Child -ccontains 'undeclared=') `
            "Invoke-PerGuestNewVm must probe for -ExposeVirtualizationExtensions before forwarding; the guest script was handed: $($undeclared.Child -join ' | ')"
        Assert-True (@($undeclared.Verbose | Where-Object { $_ -cmatch "^Cascaded -ExposeVirtualizationExtensions 'true' NOT forwarded: .* does not declare an -ExposeVirtualizationExtensions parameter\.$" }).Count -eq 1) `
            'a dropped -ExposeVirtualizationExtensions must be reported on the Verbose stream'
        $declared = Invoke-DispatcherFixture -Declare @('ExposeVirtualizationExtensions') -Bind $request
        Assert-True ($declared.Child -ccontains 'ExposeVirtualizationExtensions=true') `
            "a probed-and-present -ExposeVirtualizationExtensions must reach the child script; it reported: $($declared.Child -join ' | ')"
    }
    It 'host-contract New-VM wrappers declare -ExposeVirtualizationExtensions: <name>' -TestCases $script:hostCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$ExposeVirtualizationExtensions\b') `
            "$name New-VM wrapper must declare -ExposeVirtualizationExtensions so @PSBoundParameters carries it to the dispatcher"
    }
    It 'planner, runner, and both forward sites carry the effective field' {
        Assert-True ($script:plannerSrc -match 'effectiveExposeVirtualizationExtensions') 'planner must extract exposeVirtualizationExtensions from the cascade'
        Assert-True ($script:runnerSrc -match 'effectiveExposeVirtualizationExtensions') 'Resolve-TestSequencePlan must surface exposeVirtualizationExtensions'
        Assert-True ($script:seqEntrySrc -match [regex]::Escape('$newVmArgs.ExposeVirtualizationExtensions')) 'Debug-TestSequence must forward exposeVirtualizationExtensions'
        Assert-True ($script:innerSrc -match [regex]::Escape('$newVmArgs.ExposeVirtualizationExtensions')) 'the runner must forward exposeVirtualizationExtensions'
    }
}
