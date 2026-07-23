<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42b03f81-d5c7-4c8e-bea6-7a081b3285e2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host contract facade pester
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
    Pester coverage for Test.HostContract.psm1: the facade that fans a single
    import out into the four Test.Host* siblings.
.DESCRIPTION
    The facade's whole job is reachability: a caller that only knows the
    facade (the runner, Test-Sequence.ps1, sequence extensions) must get the
    entire Test.Host* surface from one Import-Module. So the tests assert
    behaviour, not shape: all four siblings load, every function name the
    facade names in its Export-ModuleMember list actually resolves and comes
    from a Test.Host* sibling (the drift guard -- a sibling rename that the
    facade is not told about fails here), the surface survives the -Force
    sibling re-import that a second facade load performs, and a function
    reached through the facade really runs.
    Nothing is imported from a host driver and no VM is touched.
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4
    and Pester 5+. Run: Invoke-Pester -Path test/modules/Test.HostContract.Tests.ps1
#>

$here         = Split-Path -Parent $PSCommandPath
$contractPath = Join-Path $here 'Test.HostContract.psm1'
Import-Module $contractPath -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# The four siblings the facade promises to pull in.
$siblingModule = @('Test.HostDetection', 'Test.HostCondition', 'Test.HostGit', 'Test.HostBootstrap')
$siblingCase   = @($siblingModule | ForEach-Object { @{ name = $_ } })

# The facade's Export-ModuleMember list, read straight out of its source: it is
# the written-down contract, and the tests below hold the code to it. Parsing
# it (rather than restating it here) means a name added to the facade is
# checked automatically instead of quietly going untested.
$facadeSource   = Get-Content -Raw -LiteralPath $contractPath
$exportMatch    = [regex]::Match($facadeSource, '(?s)Export-ModuleMember\s+-Function\s+(?<names>.+)$')
$declaredExport = @()
if ($exportMatch.Success) {
    $declaredExport = @(
        ($exportMatch.Groups['names'].Value -replace '`\s*\r?\n', ' ') -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ }
    )
}
$exportCase = @($declaredExport | ForEach-Object { @{ name = $_ } })

Describe 'Test.HostContract facade' {

    Context 'sibling fan-out' {

        It 'loads every Test.Host* sibling from a single import' -TestCases $siblingCase {
            param($name)
            Assert-True ([bool](Get-Module -Name $name)) "importing the facade must load '$name'"
        }
    }

    Context 'declared surface' {

        # Non-vacuity guard: the -TestCases below are generated from the parse
        # above. If the parse ever came back empty, Pester would generate zero
        # tests and the whole Context would pass while checking nothing.
        It 'parses a non-trivial export list out of the facade source' {
            Assert-True ($declaredExport.Count -ge 10) "expected the facade to declare a real surface; parsed $($declaredExport.Count) name(s)"
            Assert-True ($declaredExport -contains 'Get-HostType')          'the parse must find the detection entry point'
            Assert-True ($declaredExport -contains 'Initialize-YurunaHost') 'the parse must find the bootstrap entry point'
        }

        It 'resolves every function the facade declares' -TestCases $exportCase {
            param($name)
            $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue
            Assert-True ([bool]$cmd) "the facade declares '$name' but nothing in the session provides it"
            Assert-Equal -Expected 'Function' -Actual "$($cmd.CommandType)" -Because 'the contract is a set of functions, not aliases or external binaries'
        }

        It 'sources every declared function from a Test.Host* sibling' -TestCases $exportCase {
            param($name)
            $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue
            Assert-True ([bool]$cmd) "the facade declares '$name' but nothing in the session provides it"
            Assert-True ($cmd.ModuleName -like 'Test.Host*') `
                "'$name' resolved to module '$($cmd.ModuleName)'; a facade name that drifts off the Test.Host* family is a broken contract"
        }
    }

    Context 'repeat import' {

        # The facade re-imports its siblings with -Force, which evicts and
        # reloads them. The runner reloads the facade every cycle, so a
        # re-import that left the session without the names would break the
        # harness at an arbitrary point mid-run rather than at load.
        It 'keeps the surface intact across a second -Force import' {
            Import-Module $contractPath -Force -DisableNameChecking
            foreach ($m in $siblingModule) {
                Assert-True ([bool](Get-Module -Name $m)) "'$m' must survive a facade reload"
            }
            Assert-True ([bool](Get-Command -Name 'Get-HostType'          -ErrorAction SilentlyContinue)) 'Get-HostType must survive a facade reload'
            Assert-True ([bool](Get-Command -Name 'Initialize-YurunaHost' -ErrorAction SilentlyContinue)) 'Initialize-YurunaHost must survive a facade reload'
        }
    }

    Context 'behaviour through the facade' {

        It 'runs a sibling function reached only through the facade' -TestCases @(
            @{ hostType = 'host.windows.hyper-v'; folder = 'host/windows.hyper-v' }
            @{ hostType = 'host.ubuntu.kvm';      folder = 'host/ubuntu.kvm' }
            @{ hostType = 'host.macos.utm';       folder = 'host/macos.utm' }
        ) {
            param($hostType, $folder)
            Assert-Equal -Expected $folder -Actual (Get-HostFolder -HostType $hostType) `
                -Because 'the facade must hand back a working function, not just a resolvable name'
        }

        It 'exposes the host-driver bootstrap that the runner dispatches through' {
            $cmd = Get-Command -Name 'Initialize-YurunaHost' -ErrorAction SilentlyContinue
            Assert-True ([bool]$cmd) 'the facade must reach the bootstrap sibling'
            Assert-Equal -Expected 'Test.HostBootstrap' -Actual "$($cmd.ModuleName)" `
                -Because 'the host-driver import is the one piece of the contract that is not detection/condition/git'
            Assert-True ($cmd.Parameters.ContainsKey('RepoRoot')) 'the runner passes the already-resolved repo root'
            Assert-True ($cmd.Parameters.ContainsKey('HostType')) 'tests simulating another host override the detected type'
        }
    }
}
