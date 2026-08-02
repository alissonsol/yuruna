<#PSScriptInfo
.VERSION 2026.08.02
.GUID 42e5a9c1-3b7d-4f28-9a06-1c2d3e4f5a6b
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
    `variables.username` / `variables.hostname` do.
.DESCRIPTION
    The value crosses the same files (planner -> runner/Invoke-TestSequence -> the
    Invoke-PerGuestNewVm dispatcher -> the per-guest New-VM.ps1), and the
    dispatcher forwards -MemoryStartupBytes/-Cores only to scripts that DECLARE
    them, dropping them on the Verbose stream otherwise. A guest script that
    forgets the parameter therefore fails silently: the VM builds, at the wrong
    size. These guards make that omission a test failure.

    ConvertTo-MemoryStartupBytes is exercised functionally; everything else is
    source-text only (no host driver imported, no VM touched). Throw-based
    assertions so the file runs under Pester 4.10.1 and Pester 5+.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# The guest scripts wired for sizing overrides: ubuntu.server.24 on every host.
$guestPaths = @(
    'host/windows.hyper-v/guest.ubuntu.server.24/New-VM.ps1',
    'host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1',
    'host/macos.utm/guest.ubuntu.server.24/New-VM.ps1'
) | ForEach-Object { Join-Path $repoRoot $_ }
$guestCase = @($guestPaths | ForEach-Object { @{ name = (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $_))); path = $_ } })

$hostContract = @(
    'host/windows.hyper-v/modules/Yuruna.Host.psm1',
    'host/ubuntu.kvm/modules/Yuruna.Host.psm1',
    'host/macos.utm/modules/Yuruna.Host.psm1'
) | ForEach-Object { Join-Path $repoRoot $_ }
$hostCase = @($hostContract | ForEach-Object { @{ name = (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $_))); path = $_ } })

$provisionSrc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'host/modules/Yuruna.HostProvision.psm1')
$plannerSrc   = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.SequencePlanner.psm1')
$runnerSrc    = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.SequenceRunner.psm1')
$innerSrc     = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.RunnerInnerLoop.psm1')
$seqEntrySrc  = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/Invoke-TestSequence.ps1')

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
    It 'finds the wired guest scripts (fixture sanity)' {
        Assert-True ($guestPaths.Count -eq 3) "expected 3 wired guest scripts, found $($guestPaths.Count)"
        foreach ($p in $guestPaths) { Assert-True (Test-Path -LiteralPath $p) "missing guest script: $p" }
    }
    It 'declares -MemoryStartupBytes so the dispatcher forwards it: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$MemoryStartupBytes\s*=\s*''''') `
            "$name has no [string]`$MemoryStartupBytes = '' parameter; Invoke-PerGuestNewVm would drop the cascade to Verbose"
    }
    It 'declares -Cores so the dispatcher forwards it: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$Cores\s*=\s*''''') `
            "$name has no [string]`$Cores = '' parameter"
    }
    It 'resolves memory through ConvertTo-MemoryStartupBytes: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match 'ConvertTo-MemoryStartupBytes\s+\$MemoryStartupBytes') `
            "$name must normalize `$MemoryStartupBytes via the shared helper"
    }
    It 'guards the cores override on a non-empty -Cores: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match [regex]::Escape('if ($Cores) {')) `
            "$name must only override vCPU count when -Cores was actually passed"
        Assert-True ($src -match [regex]::Escape('$vmCores = $coresInt')) `
            "$name must apply the parsed core count to `$vmCores"
    }
}

Describe 'vm-sizing -- the dispatcher forwards under the declare-or-drop rule' {
    It 'probes the target script for -MemoryStartupBytes and -Cores' {
        Assert-True ($provisionSrc -match [regex]::Escape("ContainsKey('MemoryStartupBytes')")) `
            'Invoke-PerGuestNewVm must probe for -MemoryStartupBytes before forwarding'
        Assert-True ($provisionSrc -match [regex]::Escape("ContainsKey('Cores')")) `
            'Invoke-PerGuestNewVm must probe for -Cores before forwarding'
    }
    It 'appends -MemoryStartupBytes and -Cores to the child argument list' {
        Assert-True ($provisionSrc -match [regex]::Escape("@('-MemoryStartupBytes', `$MemoryStartupBytes)")) `
            'a probed-and-present -MemoryStartupBytes must reach the child script'
        Assert-True ($provisionSrc -match [regex]::Escape("@('-Cores', `$Cores)")) `
            'a probed-and-present -Cores must reach the child script'
    }
}

Describe 'vm-sizing -- host-contract New-VM wrappers declare the pass-through params' {
    It 'declares -MemoryStartupBytes and -Cores: <name>' -TestCases $hostCase {
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
        Assert-True ($plannerSrc -match 'effectiveMemoryStartupBytes') 'planner must extract memoryStartupBytes from the cascade'
        Assert-True ($plannerSrc -match 'effectiveCores') 'planner must extract cores from the cascade'
    }
    It 'Test.SequenceRunner returns them from Resolve-TestSequencePlan' {
        Assert-True ($runnerSrc -match 'effectiveMemoryStartupBytes') 'Resolve-TestSequencePlan must surface memoryStartupBytes'
        Assert-True ($runnerSrc -match 'effectiveCores') 'Resolve-TestSequencePlan must surface cores'
    }
    It 'both forward sites add MemoryStartupBytes/Cores to newVmArgs' {
        Assert-True ($seqEntrySrc -match [regex]::Escape('$newVmArgs.MemoryStartupBytes')) 'Invoke-TestSequence must forward memory'
        Assert-True ($seqEntrySrc -match [regex]::Escape('$newVmArgs.Cores')) 'Invoke-TestSequence must forward cores'
        Assert-True ($innerSrc -match [regex]::Escape('$newVmArgs.MemoryStartupBytes')) 'the runner must forward memory'
        Assert-True ($innerSrc -match [regex]::Escape('$newVmArgs.Cores')) 'the runner must forward cores'
    }
}
