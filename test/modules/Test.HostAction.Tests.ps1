<#PSScriptInfo
.VERSION 2026.07.24
.GUID 7c1d4e9a-3b28-4f60-9d15-6ae2c8f01b73
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostaction sequence gate pester
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
    Guards Get-HostActionFinding (Test.ConfigValidator.psm1): the pre-cycle
    static check on a sequence's `host:` block -- named scripts must exist and
    must be runnable on the DETECTED host.
.DESCRIPTION
    A `host:` sequence runs sibling scripts directly on the host, and they are
    typically destructive (lab teardown). A project authored on Windows calling
    `Hyper-V\Get-VM` used to fail only mid-cycle on step 1, after the cycle had
    re-cloned the project and started tearing VMs down -- so the gate must
    decide this WITHOUT executing anything. Throw-based assertions so the file
    runs under Pester 4.10.1 and Pester 5+.
    Run: Invoke-Pester -Path test/modules/Test.HostAction.Tests.ps1
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.ConfigValidator.psm1'

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }

Import-Module $modulePath -Force -DisableNameChecking -Global

# One scratch dir for the whole file: every case writes a sequence + its sibling
# script(s) here, because the resolution under test is "relative to the sequence
# file's folder" and a fixture that lived elsewhere would not exercise it.
$script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-hostaction-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:FixtureRoot -Force | Out-Null

function New-Fixture {
    <# Writes <name>.yml plus any sibling scripts; returns the sequence path. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer under a per-run temp dir; -WhatIf has no meaning for it.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Scripts,   # filename -> content
        [string[]]$Declared,                          # names to list under host.scripts
        [switch]$NoHostBlock,
        [string]$SingularScript                       # use `host.script:` instead
    )
    $dir = Join-Path $script:FixtureRoot $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($fileName in $Scripts.Keys) {
        Set-Content -LiteralPath (Join-Path $dir $fileName) -Value $Scripts[$fileName] -Encoding UTF8
    }
    $seqPath = Join-Path $dir "$Name.yml"
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("name: $Name")
    if (-not $NoHostBlock) {
        [void]$lines.Add('host:')
        [void]$lines.Add('  elevated: true')
        if ($SingularScript) {
            [void]$lines.Add("  script: $SingularScript")
        } elseif ($Declared) {
            [void]$lines.Add('  scripts:')
            foreach ($d in $Declared) { [void]$lines.Add("    - $d") }
        }
    }
    Set-Content -LiteralPath $seqPath -Value $lines -Encoding UTF8
    return $seqPath
}

function Get-Finding {
    # -NoEnumerate so a SINGLE finding still reaches the caller as an array.
    # Without it the lone hashtable unrolls and `.Count` silently returns 3 --
    # its key count -- which reads as "three findings" instead of one.
    param([string]$SequencePath, [string]$HostType = 'host.ubuntu.kvm')
    $seq = Get-Content -Raw -LiteralPath $SequencePath | ConvertFrom-Yaml -Ordered
    Write-Output -NoEnumerate -InputObject @(Get-HostActionFinding -Sequence $seq -SequencePath $SequencePath -HostType $HostType)
}

# Realistic stand-ins for the two shapes that actually broke a cycle.
$script:WindowsOnly = @'
param([string]$YurunaRoot = 'c:\git\yuruna')
if (Hyper-V\Get-VM -Name 'lab' -ErrorAction SilentlyContinue) { Hyper-V\Stop-VM -Name 'lab' }
$p = Join-Path -Path $YurunaRoot -ChildPath 'test/Remove-OrphanedVMFiles.ps1'
'@

$script:Portable = @'
param([string]$YurunaRoot = "$PSScriptRoot/..")
Write-Output "tearing down under $YurunaRoot"
'@

Describe 'Get-HostActionFinding -- sequences with no host action' {
    It 'returns nothing for a sequence that declares no host block' {
        $p = New-Fixture -Name 'noblock' -Scripts @{} -NoHostBlock
        Assert-Equal 0 (Get-Finding -SequencePath $p).Count -Because 'a guest sequence must not be flagged'
    }
    It 'returns nothing for a null sequence document' {
        Assert-Equal 0 @(Get-HostActionFinding -Sequence $null -SequencePath 'x.yml' -HostType 'host.ubuntu.kvm').Count -Because 'an unparsed doc must not throw or invent findings'
    }
    It 'fails a host block that names no script at all' {
        $p = New-Fixture -Name 'emptyblock' -Scripts @{}
        $f = Get-Finding -SequencePath $p
        Assert-Equal 1 $f.Count -Because 'exactly one finding'
        Assert-Equal 'Fail' $f[0].Severity -Because 'the orchestrator errors on this immediately, so the gate must too'
    }
}

Describe 'Get-HostActionFinding -- the script must exist next to its sequence' {
    It 'fails when a declared script is missing' {
        $p = New-Fixture -Name 'missing' -Scripts @{} -Declared @('Nope.ps1')
        $f = Get-Finding -SequencePath $p
        Assert-Equal 1 $f.Count -Because 'one missing script -> one finding'
        Assert-Equal 'Fail' $f[0].Severity -Because 'a missing host script must block the cycle'
        Assert-True ($f[0].Message -match 'Nope\.ps1') 'the message names the missing script'
    }
    It 'resolves the singular host.script form too' {
        $p = New-Fixture -Name 'singular' -Scripts @{} -SingularScript 'AlsoNope.ps1'
        $f = Get-Finding -SequencePath $p
        Assert-Equal 'Fail' $f[0].Severity -Because 'host.script must be validated exactly like host.scripts'
        Assert-True ($f[0].Message -match 'AlsoNope\.ps1') 'the singular form names its script'
    }
    It 'passes a portable script that exists' {
        $p = New-Fixture -Name 'clean' -Scripts @{ 'Teardown.ps1' = $script:Portable } -Declared @('Teardown.ps1')
        Assert-Equal 0 (Get-Finding -SequencePath $p).Count -Because 'a portable, present script is clean'
    }
}

Describe 'Get-HostActionFinding -- Hyper-V dependence vs the detected host' {
    # The regression: a Windows-authored teardown ran on host.ubuntu.kvm and
    # died partway through, AFTER its destructive work had begun.
    It 'FAILS a Hyper-V-dependent script on a KVM host' {
        $p = New-Fixture -Name 'hv-kvm' -Scripts @{ 'Clear.ps1' = $script:WindowsOnly } -Declared @('Clear.ps1')
        $f = Get-Finding -SequencePath $p -HostType 'host.ubuntu.kvm'
        $fails = @($f | Where-Object { $_.Severity -eq 'Fail' })
        Assert-Equal 1 $fails.Count -Because 'the Hyper-V dependence must be a hard failure'
        Assert-True ($fails[0].Message -match 'Hyper-V\\Get-VM') 'the message names the offending cmdlet'
        Assert-True ($fails[0].Message -match 'host\.ubuntu\.kvm')  'the message names the host it cannot run on'
        Assert-True ($fails[0].Message -match 'line 2')             'the message points at the line'
    }
    It 'FAILS the same script on a macOS host' {
        $p = New-Fixture -Name 'hv-mac' -Scripts @{ 'Clear.ps1' = $script:WindowsOnly } -Declared @('Clear.ps1')
        $f = @((Get-Finding -SequencePath $p -HostType 'host.macos.utm') | Where-Object { $_.Severity -eq 'Fail' })
        Assert-Equal 1 $f.Count -Because 'Hyper-V is unavailable on macOS too'
    }
    It 'does NOT flag Hyper-V on the Windows host it was written for' {
        $p = New-Fixture -Name 'hv-win' -Scripts @{ 'Clear.ps1' = $script:WindowsOnly } -Declared @('Clear.ps1')
        Assert-Equal 0 (Get-Finding -SequencePath $p -HostType 'host.windows.hyper-v').Count -Because 'the check must not fire where the module genuinely exists'
    }
    It 'does not confuse an unrelated Get-VM with the Hyper-V-qualified one' {
        # Bare Get-VM is the framework's own cross-platform helper; only the
        # module-qualified call is decidable as Windows-only.
        $p = New-Fixture -Name 'bare-getvm' -Scripts @{ 'Clear.ps1' = "param()`nGet-VM -Name 'lab'`n" } -Declared @('Clear.ps1')
        Assert-Equal 0 (Get-Finding -SequencePath $p).Count -Because 'an unqualified Get-VM says nothing about the platform'
    }
}

Describe 'Get-HostActionFinding -- Windows-absolute parameter defaults' {
    It 'WARNS (does not fail) on a drive-letter default on a non-Windows host' {
        # host.arguments can override a default, so this is a hazard, not a verdict.
        $p = New-Fixture -Name 'drive' -Scripts @{ 'Clear.ps1' = "param([string]`$YurunaRoot = 'c:\git\yuruna')`nWrite-Output `$YurunaRoot`n" } -Declared @('Clear.ps1')
        $f = Get-Finding -SequencePath $p
        Assert-Equal 1 $f.Count -Because 'one hazard'
        Assert-Equal 'Warn' $f[0].Severity -Because 'an overridable default must not block the cycle'
        Assert-True ($f[0].Message -match 'Cannot find drive') 'the message explains the failure the operator would otherwise see'
    }
    It 'does not warn on a relative or PSScriptRoot-based default' {
        $p = New-Fixture -Name 'relative' -Scripts @{ 'Clear.ps1' = $script:Portable } -Declared @('Clear.ps1')
        Assert-Equal 0 (Get-Finding -SequencePath $p).Count -Because 'portable defaults are fine'
    }
    It 'does not warn about a drive-letter default on Windows' {
        $p = New-Fixture -Name 'drive-win' -Scripts @{ 'Clear.ps1' = "param([string]`$Root = 'c:\git\yuruna')`nWrite-Output `$Root`n" } -Declared @('Clear.ps1')
        Assert-Equal 0 (Get-Finding -SequencePath $p -HostType 'host.windows.hyper-v').Count -Because 'a Windows path on Windows is correct, not a hazard'
    }
}

Describe 'Get-HostActionFinding -- robustness' {
    It 'fails a host script that does not parse' {
        $p = New-Fixture -Name 'broken' -Scripts @{ 'Clear.ps1' = "param(`nfunction {{{" } -Declared @('Clear.ps1')
        $f = Get-Finding -SequencePath $p
        Assert-Equal 'Fail' $f[0].Severity -Because 'a script that cannot parse cannot run'
        Assert-True ($f[0].Message -match 'does not parse') 'the message says why'
    }
    It 'checks existence but skips platform checks when the host type is unknown' {
        $p = New-Fixture -Name 'nohosttype' -Scripts @{ 'Clear.ps1' = $script:WindowsOnly } -Declared @('Clear.ps1')
        $seq = Get-Content -Raw -LiteralPath $p | ConvertFrom-Yaml -Ordered
        Assert-Equal 0 @(Get-HostActionFinding -Sequence $seq -SequencePath $p -HostType '').Count -Because 'with no detected host we cannot judge the platform -- and must not guess'
    }
    It 'reports every declared script, not just the first' {
        # The real cycle only ever reached script 1; the gate must surface both.
        $p = New-Fixture -Name 'twoscripts' -Scripts @{
            'Clear.ps1' = $script:WindowsOnly
            'Build.ps1' = $script:WindowsOnly
        } -Declared @('Clear.ps1', 'Build.ps1')
        $fails = @((Get-Finding -SequencePath $p) | Where-Object { $_.Severity -eq 'Fail' })
        Assert-Equal 2 $fails.Count -Because 'both host scripts must be reported in one pass'
    }
    It 'points the finding at the offending SCRIPT, not the sequence' {
        $p = New-Fixture -Name 'pathing' -Scripts @{ 'Clear.ps1' = $script:WindowsOnly } -Declared @('Clear.ps1')
        $fails = @((Get-Finding -SequencePath $p) | Where-Object { $_.Severity -eq 'Fail' })
        Assert-True ($fails[0].Path -match 'Clear\.ps1$') 'the operator needs to open the script, not the yml'
    }
}

Describe 'Test-Config.ps1 wires the host-action gate in' {
    It 'calls Get-HostActionFinding while scanning sequences, passing the detected host type' {
        $repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
        $text = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/Test-Config.ps1')
        Assert-True ($text -match 'Get-HostActionFinding')  'the gate must run the host-action check'
        Assert-True ($text -match 'Get-HostActionFinding[^\r\n]*-HostType\s+\$HostType') 'it must pass the DETECTED host type, or the platform checks silently no-op'
    }
    It 'exports the analyzer from Test.ConfigValidator' {
        $mod = Get-Content -Raw -LiteralPath $modulePath
        Assert-True ($mod -match 'Export-ModuleMember[^\r\n]*Get-HostActionFinding') 'Test-Config.ps1 reaches it through the module export'
    }
}
