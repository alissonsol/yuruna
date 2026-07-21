<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42ca0b24-d5cf-4c36-8488-7537249b3b3d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host redirect pester
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
    Pester coverage for automation/Yuruna.HostRedirect.psm1: the hop from a
    host-neutral entry point in test/ to this host's copy of a script under
    host/<host type>/.
.DESCRIPTION
    Throw-based assertions, helpers at file scope (Pester 5's scope split hides
    Describe-scoped helpers from It blocks).

    The cases that matter are the ones that fail SILENTLY in production:

      * an argument carrying spaces or quotes must cross the process boundary
        as ONE argv entry -- under Legacy native-argument passing it is re-split
        and the per-host script binds the wrong values;
      * a non-zero child exit must come back as an exit CODE, not as a
        NativeCommandExitException -- the per-host cleanup scripts exit non-zero
        to report partial work, and a caller running under
        $ErrorActionPreference='Stop' would otherwise lose the code;
      * the caller's location must be restored even when the child fails;
      * elevation must be decided from the target's own `#requires` line, so a
        host script that starts or stops needing Administrator stays correct
        with no edit to the redirector.

    Host-independent by construction: fixtures build a throwaway repo carrying
    all three host folders, so the -HostType cases run identically on every
    host, and the end-to-end cases use whatever Get-HostType reports here.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $repoRoot 'automation/Yuruna.HostRedirect.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because='') if ($Condition) { throw "Expected false. $Because" } }
function Assert-Throw {
    param([scriptblock]$Action, [string]$Match, [string]$Because='')
    try { & $Action } catch {
        if ($Match -and $_.Exception.Message -notmatch $Match) {
            throw "Threw, but message [$($_.Exception.Message)] does not match [$Match]. $Because"
        }
        return
    }
    throw "Expected a throw. $Because"
}

function New-RedirectFixture {
    <#
    .SYNOPSIS
        Build a throwaway repo: all three host folders, each with the probes,
        plus the real host-detection module so the redirector resolves the host
        exactly the way it does in the live repo.
    .DESCRIPTION
        The probe bodies are declared HERE rather than at file scope: Pester
        runs a test file's top level during discovery only, and a variable set
        there is gone by the time an It block calls this function -- the probe
        files would be written empty, and every assertion about their content
        would fail for a reason that has nothing to do with the code under test.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp directory tree; no production state.')]
    [OutputType([hashtable])]
    param()

    # Stands in for a per-host script: reports what it received and exits 7, so
    # a test can tell a propagated exit code from a swallowed one (0 would be
    # indistinguishable from "the redirector never ran anything").
    $probeBody = @'
#requires -version 7
param(
    [string]$ReferenceHost,
    [switch]$NonInteractive,
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
Write-Output "CWD=$((Get-Location).Path)"
Write-Output "REFHOST=[$ReferenceHost]"
Write-Output "NONINTERACTIVE=$($NonInteractive.IsPresent)"
Write-Output "REST=[$($Rest -join '+')]"
exit 7
'@

    $probeAdminBody = @'
#requires -version 7
#requires -RunAsAdministrator
Write-Output 'NEVER-RUNS'
'@

    # A target whose text merely MENTIONS the elevation requirement, in a
    # comment and in a string. The parser must not count either -- a regex would.
    $probeDecoyBody = @'
#requires -version 7
# This script does not need "#requires -RunAsAdministrator" any more.
$note = '#requires -RunAsAdministrator'
Write-Output $note
'@

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-redirect-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'test/modules') -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'test/modules/Test.HostDetection.psm1') (Join-Path $root 'test/modules') -Force
    foreach ($shortName in @('windows.hyper-v', 'macos.utm', 'ubuntu.kvm')) {
        $folder = Join-Path $root "host/$shortName"
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content (Join-Path $folder 'Probe.ps1')      $probeBody      -Encoding ascii
        Set-Content (Join-Path $folder 'ProbeAdmin.ps1') $probeAdminBody -Encoding ascii
        Set-Content (Join-Path $folder 'ProbeDecoy.ps1') $probeDecoyBody -Encoding ascii
    }
    return @{ Root = $root }
}

function Remove-RedirectFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test teardown: removes the temp directory tree.')]
    param([Parameter(Mandatory)][hashtable]$Fixture)
    Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ScriptRequiresElevation' {

    It 'is true only when the target really declares #requires -RunAsAdministrator' {
        $fx = New-RedirectFixture
        try {
            $folder = Join-Path $fx.Root 'host/windows.hyper-v'
            Assert-True  (Test-ScriptRequiresElevation -Path (Join-Path $folder 'ProbeAdmin.ps1')) 'declared requirement'
            Assert-False (Test-ScriptRequiresElevation -Path (Join-Path $folder 'Probe.ps1'))      'no requirement'
        } finally { Remove-RedirectFixture -Fixture $fx }
    }

    It 'ignores the phrase in a comment or a string (parsed, not pattern-matched)' {
        $fx = New-RedirectFixture
        try {
            $decoy = Join-Path $fx.Root 'host/windows.hyper-v/ProbeDecoy.ps1'
            Assert-False (Test-ScriptRequiresElevation -Path $decoy) 'a mention is not a requirement'
        } finally { Remove-RedirectFixture -Fixture $fx }
    }

    It 'agrees with the live host scripts: the two Windows ones, and only those' {
        Assert-True  (Test-ScriptRequiresElevation -Path (Join-Path $repoRoot 'host/windows.hyper-v/Enable-TestAutomation.ps1'))  'windows Enable'
        Assert-True  (Test-ScriptRequiresElevation -Path (Join-Path $repoRoot 'host/windows.hyper-v/Sync-HostConfiguration.ps1')) 'windows Sync'
        Assert-False (Test-ScriptRequiresElevation -Path (Join-Path $repoRoot 'host/macos.utm/Enable-TestAutomation.ps1'))        'macos Enable asks for sudo itself'
        Assert-False (Test-ScriptRequiresElevation -Path (Join-Path $repoRoot 'host/ubuntu.kvm/Enable-TestAutomation.ps1'))       'ubuntu Enable asks for sudo itself'
    }
}

Describe 'Resolve-YurunaHostScript' {

    It 'maps every host type to its own folder, and takes a name with or without .ps1' {
        $fx = New-RedirectFixture
        try {
            foreach ($pair in @(
                @{ Type = 'host.windows.hyper-v'; Short = 'windows.hyper-v' },
                @{ Type = 'host.macos.utm';       Short = 'macos.utm' },
                @{ Type = 'host.ubuntu.kvm';      Short = 'ubuntu.kvm' })) {

                $withSuffix = Resolve-YurunaHostScript -ScriptName 'Probe.ps1' -RepoRoot $fx.Root -HostType $pair.Type
                $bareName   = Resolve-YurunaHostScript -ScriptName 'Probe'     -RepoRoot $fx.Root -HostType $pair.Type

                Assert-Equal -Expected $pair.Type -Actual $withSuffix.HostType
                Assert-Equal -Expected "host/$($pair.Short)/Probe.ps1" -Actual $withSuffix.RelativePath
                Assert-Equal -Expected $withSuffix.Path -Actual $bareName.Path -Because '.ps1 is appended when omitted'
                Assert-True  (Test-Path -LiteralPath $withSuffix.Path) 'resolved path exists'
            }
        } finally { Remove-RedirectFixture -Fixture $fx }
    }

    It 'surfaces the elevation requirement it read from the target' {
        $fx = New-RedirectFixture
        try {
            $plain = Resolve-YurunaHostScript -ScriptName 'Probe'      -RepoRoot $fx.Root -HostType 'host.windows.hyper-v'
            $admin = Resolve-YurunaHostScript -ScriptName 'ProbeAdmin' -RepoRoot $fx.Root -HostType 'host.windows.hyper-v'
            Assert-False $plain.RequiresElevation
            Assert-True  $admin.RequiresElevation
        } finally { Remove-RedirectFixture -Fixture $fx }
    }

    It 'throws naming the host type when the script is not available for it' {
        $fx = New-RedirectFixture
        try {
            Assert-Throw { Resolve-YurunaHostScript -ScriptName 'NotThere' -RepoRoot $fx.Root -HostType 'host.macos.utm' } `
                -Match 'not available for host\.macos\.utm' -Because 'the error must say which host lacks it'
        } finally { Remove-RedirectFixture -Fixture $fx }
    }
}

Describe 'ConvertTo-HostScriptArgument' {

    It 'forwards only what was passed, so an omitted parameter keeps the target default' {
        $bound = @{ ReferenceHost = 'alius202607a1' }
        $argv  = @(ConvertTo-HostScriptArgument -BoundParameters $bound)
        Assert-Equal -Expected 2 -Actual $argv.Count -Because 'StatusPort was never passed, so it is not forwarded'
        Assert-Equal -Expected '-ReferenceHost' -Actual $argv[0]
        Assert-Equal -Expected 'alius202607a1'  -Actual $argv[1]
    }

    It 'emits a present switch and drops an explicitly false one' {
        $bound = @{ NonInteractive = [switch]$true; SkipValidation = [switch]$false }
        $argv  = @(ConvertTo-HostScriptArgument -BoundParameters $bound)
        Assert-Equal -Expected 1 -Actual $argv.Count
        Assert-Equal -Expected '-NonInteractive' -Actual $argv[0] -Because '-Switch:$false means the same as omitting it'
    }

    It 'never auto-forwards common parameters (not every target is an advanced script)' {
        $bound = @{ Verbose = [switch]$true; ErrorAction = 'Stop'; Force = [switch]$true }
        $argv  = @(ConvertTo-HostScriptArgument -BoundParameters $bound)
        Assert-Equal -Expected 1 -Actual $argv.Count
        Assert-Equal -Expected '-Force' -Actual $argv[0] -Because 'Verbose/ErrorAction bind to the redirector, not the child'
    }

    It 'keeps a value carrying spaces and quotes as ONE element' {
        $bound = @{ SharedToken = 'tok en "with" spaces' }
        $argv  = @(ConvertTo-HostScriptArgument -BoundParameters $bound)
        Assert-Equal -Expected 2 -Actual $argv.Count
        Assert-Equal -Expected 'tok en "with" spaces' -Actual $argv[1] -Because 'the value must not be split on whitespace'
    }

    It 'appends -ExtraArgument, then the catch-all, and drops the excluded names' {
        $bound = @{ Force = [switch]$true; RemainingArguments = @('-WhatIf') }
        $argv  = @(ConvertTo-HostScriptArgument -BoundParameters $bound -RemainingArguments @('-WhatIf') `
                    -Exclude 'RemainingArguments' -ExtraArgument @('-Verbose'))
        Assert-Equal -Expected '-Force'   -Actual $argv[0]
        Assert-Equal -Expected '-Verbose' -Actual $argv[1]
        Assert-Equal -Expected '-WhatIf'  -Actual $argv[2] -Because 'the catch-all goes last'
        Assert-Equal -Expected 3 -Actual $argv.Count -Because 'the catch-all is not forwarded twice'
    }

    It 'returns an empty array when there is nothing to forward' {
        $argv = @(ConvertTo-HostScriptArgument -BoundParameters @{})
        Assert-Equal -Expected 0 -Actual $argv.Count
    }
}

Describe 'Invoke-YurunaHostScript' {

    It 'runs the child IN the host folder and hands back its non-zero exit code' {
        $fx = New-RedirectFixture
        $startLocation = (Get-Location).Path
        try {
            # 'Stop' is what the redirectors run under. A non-zero child exit
            # must still arrive as a code, not as a NativeCommandExitException.
            $ErrorActionPreference = 'Stop'
            $out = @(Invoke-YurunaHostScript -ScriptName 'Probe' -RepoRoot $fx.Root -ArgumentList @(
                '-ReferenceHost', 'alius202607a1',
                '-NonInteractive',
                '-WhatIf'))
            $code = $LASTEXITCODE

            $expectedCwd = (Resolve-Path -LiteralPath (Join-Path $fx.Root (Get-HostFolder (Get-HostType)))).Path
            Assert-Equal -Expected 7 -Actual $code -Because 'the child exit code is the result, not an error'
            Assert-True  ($out -contains "CWD=$expectedCwd")        "child ran in the host folder; saw: $($out -join ' / ')"
            Assert-True  ($out -contains 'REFHOST=[alius202607a1]') 'named argument crossed the process boundary'
            Assert-True  ($out -contains 'NONINTERACTIVE=True')     'switch crossed the process boundary'
            Assert-True  ($out -contains 'REST=[-WhatIf]')          'an undeclared argument rides the catch-all to the child'
            Assert-Equal -Expected $startLocation -Actual (Get-Location).Path -Because 'the caller is put back where it was'
        } finally { Remove-RedirectFixture -Fixture $fx }
    }

    It 'keeps an argument with spaces and quotes intact across the process boundary' {
        $fx = New-RedirectFixture
        try {
            $awkward = 'tok en "with" spaces'
            $out = @(Invoke-YurunaHostScript -ScriptName 'Probe' -RepoRoot $fx.Root `
                        -ArgumentList @('-ReferenceHost', $awkward) -Quiet)
            Assert-True ($out -contains "REFHOST=[$awkward]") `
                "the child must see one value, not a re-split one; saw: $($out -join ' / ')"
        } finally { Remove-RedirectFixture -Fixture $fx }
    }

    It 'prints the host banner, and -Quiet suppresses it without touching child output' {
        $fx = New-RedirectFixture
        try {
            $loud  = @(Invoke-YurunaHostScript -ScriptName 'Probe' -RepoRoot $fx.Root)
            $quiet = @(Invoke-YurunaHostScript -ScriptName 'Probe' -RepoRoot $fx.Root -Quiet)
            Assert-True  ($loud  | Where-Object { $_ -match '^Host type: host\.' }) 'banner names the detected host'
            Assert-False ($quiet | Where-Object { $_ -match '^Host type: host\.' }) '-Quiet drops the banner'
            Assert-True  ($quiet | Where-Object { $_ -match '^REFHOST=' })          '-Quiet never silences the child'
        } finally { Remove-RedirectFixture -Fixture $fx }
    }

    It 'restores the caller location even when the target cannot be resolved' {
        $fx = New-RedirectFixture
        $startLocation = (Get-Location).Path
        try {
            Assert-Throw { Invoke-YurunaHostScript -ScriptName 'NotThere' -RepoRoot $fx.Root } -Match 'not available for'
            Assert-Equal -Expected $startLocation -Actual (Get-Location).Path
        } finally { Remove-RedirectFixture -Fixture $fx }
    }

    It 'refuses an Administrator-only target instead of letting the child die on its #requires' {
        if (-not ($IsWindows -and -not (Test-IsAdministrator))) {
            Write-Warning 'Skipped: this case needs a non-elevated Windows session.'
            return
        }
        $fx = New-RedirectFixture
        $startLocation = (Get-Location).Path
        try {
            Assert-Throw { Invoke-YurunaHostScript -ScriptName 'ProbeAdmin' -RepoRoot $fx.Root } `
                -Match 'requires Administrator' -Because 'a child cannot gain elevation the caller does not hold'
            Assert-Equal -Expected $startLocation -Actual (Get-Location).Path
        } finally { Remove-RedirectFixture -Fixture $fx }
    }
}
