<#PSScriptInfo
.VERSION 2026.08.02
.GUID 42b9e3d1-7c04-4a52-9e18-3f6b28d5a4c7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test vm cleanup prefix sweep contract pester
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
    Pester coverage for prefix-based VM cleanup: the shared name filter
    (Select-NameByPrefix), the disposable-prefix resolver
    (Resolve-CleanupVmNamePrefix), and the Get-VMName contract coverage
    every host driver must provide.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4
    and Pester 5+. Every case is driven from in-memory names and config
    hashtables -- no hypervisor is queried -- so the sweep logic stays
    testable on a host with no VMs and no utmctl/virsh/Hyper-V.
    Run: Invoke-Pester -Path test/modules/Test.VmNameSweep.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.Config.psm1') -Force -DisableNameChecking

$SweepRepoRoot = $repoRoot

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

Describe 'Select-NameByPrefix' {

    It 'selects only the names carrying one of the prefixes' {
        $names = @('test-ubuntu-01', 'amisad-build', 'amisad-core', 'yuruna-caching-proxy-service')
        $got = @(Select-NameByPrefix -Name $names -Prefix @('amisad-'))
        Assert-Equal 2 $got.Count -Because 'only the two amisad- guests match'
        Assert-Equal 'amisad-build,amisad-core' ($got -join ',')
    }

    It 'accepts several prefixes at once and keeps input order' {
        $names = @('test-ubuntu-01', 'amisad-build', 'unrelated-vm')
        $got = @(Select-NameByPrefix -Name $names -Prefix @('amisad-', 'test-'))
        Assert-Equal 'test-ubuntu-01,amisad-build' ($got -join ',') -Because 'input order, not prefix order'
    }

    It 'treats an absent or empty prefix set as no filter' {
        # A caller whose prefix list resolved to nothing means "everything",
        # not "nothing" -- the opposite reading would silently sweep no VMs
        # and let leftovers accumulate unnoticed.
        $names = @('a-vm', 'b-vm')
        Assert-Equal 2 (@(Select-NameByPrefix -Name $names).Count)
        Assert-Equal 2 (@(Select-NameByPrefix -Name $names -Prefix @()).Count)
    }

    It 'matches prefixes literally rather than as wildcards' {
        # A prefix is a plain string. If it were used as a -like pattern, the
        # '*' below would match every name and the sweep would delete the
        # whole host.
        $names = @('a*b-vm', 'axb-vm', 'anything-else')
        $got = @(Select-NameByPrefix -Name $names -Prefix @('a*b-'))
        Assert-Equal 'a*b-vm' ($got -join ',') -Because 'wildcard semantics would also match axb-vm and anything-else'
    }

    It 'ignores blank candidates and blank prefixes' {
        $got = @(Select-NameByPrefix -Name @('keep-me', '', $null) -Prefix @('keep-'))
        Assert-Equal 'keep-me' ($got -join ',')
    }

    It 'returns nothing when no name matches' {
        Assert-Equal 0 (@(Select-NameByPrefix -Name @('a-vm') -Prefix @('zzz-')).Count)
    }
}

Describe 'Resolve-CleanupVmNamePrefix' {

    It 'defaults to the test prefix when nothing is configured' {
        Assert-Equal 'test-' ((Resolve-CleanupVmNamePrefix -VmStart $null) -join ',')
    }

    It 'honours a customized test-VM prefix' {
        $got = Resolve-CleanupVmNamePrefix -VmStart @{ testVmNamePrefix = 'yr-' }
        Assert-Equal 'yr-' ($got -join ',')
    }

    It 'always keeps the test prefix when extra prefixes are configured' {
        # The extra list EXTENDS the sweep; if it replaced the test prefix,
        # an operator who added a project prefix would stop sweeping the
        # framework's own guests and they would pile up every cycle.
        $got = Resolve-CleanupVmNamePrefix -VmStart @{
            testVmNamePrefix      = 'test-'
            cleanupVmNamePrefixes = @('amisad-', 'amisad.')
        }
        Assert-Equal 'test-,amisad-,amisad.' ($got -join ',') -Because 'test prefix first, then the configured extras'
    }

    It 'accepts a bare string for cleanupVmNamePrefixes' {
        $got = Resolve-CleanupVmNamePrefix -VmStart @{ cleanupVmNamePrefixes = 'amisad-' }
        Assert-Equal 'test-,amisad-' ($got -join ',')
    }

    It 'drops blank entries so the sweep never matches every VM' {
        $got = Resolve-CleanupVmNamePrefix -VmStart @{ cleanupVmNamePrefixes = @('', '  ', 'amisad-') }
        Assert-Equal 'test-,amisad-' ($got -join ',') -Because 'a stray empty list entry must not widen the sweep'
    }

    It 'de-duplicates a prefix repeated in the extra list' {
        $got = Resolve-CleanupVmNamePrefix -VmStart @{
            testVmNamePrefix      = 'test-'
            cleanupVmNamePrefixes = @('test-', 'amisad-')
        }
        Assert-Equal 'test-,amisad-' ($got -join ',')
    }
}

Describe 'Get-VMName host-driver coverage' {

    It 'is declared in the canonical host contract' {
        $contract = Get-Content -Raw (Join-Path $SweepRepoRoot 'host/Yuruna.Host.Contract.psm1')
        Assert-True ($contract -match "'Get-VMName'") 'the contract must list the inventory verb'
    }

    It 'is implemented and exported by every host driver' {
        # Enumeration was the last host-specific step in a prefix sweep. If a
        # driver stops exporting it, Remove-TestVMFiles cannot enumerate on
        # that host at all, so pin all three rather than only the host this
        # suite happens to run on.
        foreach ($driver in @('macos.utm', 'windows.hyper-v', 'ubuntu.kvm')) {
            $path = Join-Path $SweepRepoRoot "host/$driver/modules/Yuruna.Host.psm1"
            $text = Get-Content -Raw $path
            Assert-True ($text -match '(?m)^function Get-VMName\b') "$driver must define Get-VMName"
            Assert-True ($text -match "Get-VMState, Get-VMName,") "$driver must export Get-VMName"
            Assert-True ($text -match "'Get-VMState','Get-VMName'") "$driver must assert contract coverage for Get-VMName"
        }
    }

    It 'fails loudly instead of reporting an empty list when the host cannot be queried' {
        # A driver that returned @() when its CLI is unreachable would let a
        # sweep call the host clean, and the orphan-file pass behind it would
        # delete files still claimed by a registered VM.
        foreach ($driver in @('macos.utm', 'windows.hyper-v', 'ubuntu.kvm')) {
            $path = Join-Path $SweepRepoRoot "host/$driver/modules/Yuruna.Host.psm1"
            $text = Get-Content -Raw $path
            $body = [regex]::Match($text, '(?ms)^function Get-VMName\b.*?^\}').Value
            Assert-True ($body -match 'throw') "$driver Get-VMName must throw when enumeration fails"
        }
    }
}

Describe 'Remove-TestVMFiles prefix sweep' {

    It 'accepts a list of prefixes' {
        $text = Get-Content -Raw (Join-Path $SweepRepoRoot 'test/Remove-TestVMFiles.ps1')
        Assert-True ($text -match '\[string\[\]\]\$Prefix') 'the sweep must take more than one prefix'
    }

    It 'names no hypervisor in its cleanup logic' {
        # The whole point of the contract verb: one sweep implementation for
        # every host, so a fix lands on all three at once.
        $text = Get-Content -Raw (Join-Path $SweepRepoRoot 'test/Remove-TestVMFiles.ps1')
        $code = ($text -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        foreach ($token in @('utmctl', 'virsh ', 'Hyper-V\\Get-VM')) {
            Assert-True ($code -notmatch [regex]::Escape($token)) "cleanup logic must not call $token directly"
        }
    }

    It 'refuses a prefix set that resolves to nothing' {
        # An empty prefix matches every VM on the host, including the caching
        # proxy and anything unrelated the operator is running.
        $text = Get-Content -Raw (Join-Path $SweepRepoRoot 'test/Remove-TestVMFiles.ps1')
        Assert-True ($text -match 'would match every VM') 'the guard against an empty prefix must be present'
    }
}

Describe 'Concurrent-VM pre-flight' {

    It 'stops running VMs through the host contract rather than naming a hypervisor' {
        # A leftover guest has to be stopped, not reported: refusing over it
        # strands the host, because the sweep that would remove it only runs
        # once a cycle starts.
        $text = Get-Content -Raw (Join-Path $SweepRepoRoot 'test/modules/Test.HostContract.psm1')
        $body = [regex]::Match($text, '(?ms)^function Stop-ConcurrentVM\b.*?\n\}').Value
        Assert-True ($body.Length -gt 0) 'Stop-ConcurrentVM is defined'
        Assert-True ($body -match 'Get-VMName') 'enumerates through the contract'
        Assert-True ($body -match 'Stop-VMForce') 'stops through the contract'
        foreach ($token in @('utmctl', 'virsh')) {
            Assert-True ($body -notmatch $token) "must not call $token directly"
        }
    }

    It 'stops but never deletes an unrecognized VM' {
        # A running VM the framework does not recognize may be the
        # operator's. Stopping is recoverable; deleting is not. Removal is
        # the prefix sweep's job, where the prefix proves it is disposable.
        $text = Get-Content -Raw (Join-Path $SweepRepoRoot 'test/modules/Test.HostContract.psm1')
        $body = [regex]::Match($text, '(?ms)^function Stop-ConcurrentVM\b.*?\n\}').Value
        Assert-True ($body -notmatch 'Remove-VM') 'the pre-flight must not delete VMs'
    }

    It 'keeps progress out of the success stream so its return stays a boolean' {
        # This function's output IS its return value. A Write-Output here
        # makes it return an array of progress strings ending in the bool,
        # and a non-empty array is always truthy -- so `-not
        # (Stop-ConcurrentVM)` would never fire and the failure path would
        # silently stop refusing. Progress belongs on the information stream.
        $text = Get-Content -Raw (Join-Path $SweepRepoRoot 'test/modules/Test.HostContract.psm1')
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Stop-ConcurrentVM' }, $true))
        Assert-True ($fn.Count -eq 1) 'Stop-ConcurrentVM is defined once'
        $emitters = @($fn[0].FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        Assert-True ($emitters -notcontains 'Write-Output') 'no Write-Output inside a value-returning function'
        Assert-True ($emitters -contains 'Write-Information') 'progress goes to the information stream'
    }

    It 'runs before the refusal guard in both entry points' {
        foreach ($caller in @('test/modules/Invoke-TestRunnerInnerLoop.ps1', 'test/Invoke-TestSequence.ps1')) {
            $text = Get-Content -Raw (Join-Path $SweepRepoRoot $caller)
            $stopAt  = $text.IndexOf('Stop-ConcurrentVM')
            $guardAt = $text.IndexOf('Assert-NoConcurrentUtmVm -')
            Assert-True ($stopAt -ge 0) "$caller must call Stop-ConcurrentVM"
            Assert-True ($guardAt -lt 0 -or $stopAt -lt $guardAt) "$caller must stop before it refuses"
        }
    }
}
