<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42b856ad-722d-46a1-b7fb-0b117cf1cfdb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hyperv vmconnect settle performance pester
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
    Verify the vmconnect viewer wait exits once the main window has settled
    (visible, enabled, titled for the VM) for as long as the dialog's own
    worst-case appearance delay, instead of always paying a blind 2 s sleep
    plus the full dialog poll.
.DESCRIPTION
    The driver module is Windows-only (Add-Type against user32.dll, a
    vmconnect.exe process). The dynamic Describe below lifts
    Resolve-VMConnectAnotherUserDialog out of the module by text (the same
    pattern Test.StatusArchiveProvenance and Test.FrameworkArchiveScope use
    for their own Windows/host-only emitted or driver code) into a disposable
    module whose own script scope shadows $IsWindows to $true -- the
    InModuleScope technique Test.HostMetricsExporter.Tests.ps1 and
    Test.ServiceMiscScripts.Tests.ps1 already use, here applied to a module
    built on the fly rather than a named .psm1, so the REAL global automatic
    $IsWindows (and whatever depends on it, Pester's own TestRegistry
    included) is never touched. Get-VMConnectWindowState and Start-Sleep are
    stubbed inside that same disposable module, so the settle logic runs
    against a scripted sequence of observations with no desktop, no
    vmconnect.exe, and no real delay.

    This still only runs the WAIT LOOP's decision logic; the dialog branch
    calls the real [YurunaVMConnectDialog]::Dismiss, which is itself
    Windows-only (user32.dll), so the whole dynamic Describe is defined only
    when $IsWindows, per this project's platform-only-test convention. A
    static, platform-neutral Describe registers on every platform so the
    suite never reports zero tests.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModulePath = Join-Path $script:RepoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
}

Describe 'the vmconnect launch sites and the settle function (static, every platform)' {
    It 'no longer follows a vmconnect launch with a blind 2 s sleep' {
        $text = Get-Content -Raw -LiteralPath $script:ModulePath
        $text | Should -Not -Match '(?m)Start-Process -FilePath \$vmconnect -ArgumentList "localhost", \$VMName\r?\n\s*Start-Sleep -Seconds 2' `
            -Because 'the poll already tolerates a vmconnect that has not started yet'
    }
    It 'resolves one observation at a time through Get-VMConnectWindowState' {
        $functionAst = Get-YurunaTestFunctionAst -Path $script:ModulePath -Name 'Resolve-VMConnectAnotherUserDialog'
        $functionAst | Should -Not -BeNullOrEmpty
        $functionAst.Extent.Text | Should -Match 'Get-VMConnectWindowState'
    }
}

if ($IsWindows) {
    Describe 'the settle wait, driven by a scripted sequence of observations' {
        BeforeAll {
            Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Force -Global -DisableNameChecking

            function Get-FunctionFromDriver {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
                [CmdletBinding()]
                [OutputType([string])]
                param([Parameter(Mandatory)][string]$Name)
                $found = Get-YurunaTestFunctionAst -Path $script:ModulePath -Name $Name
                if (-not $found) { return '' }
                return $found.Extent.Text
            }

            # A disposable module rather than the real one: the real module is
            # 6000+ lines of Windows-only driver code this suite has no reason
            # to load, and shadowing $IsWindows safely needs a module of its
            # own (see the file synopsis).
            function New-VMConnectInvoker {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Builds a disposable module in memory; there is nothing for an operator to confirm.')]
                [CmdletBinding()]
                param()
                $text = Get-FunctionFromDriver -Name 'Resolve-VMConnectAnotherUserDialog'
                if (-not $text) { throw 'Resolve-VMConnectAnotherUserDialog is not in the driver module' }
                $scaffold = @'
Set-Variable -Name IsWindows -Value $true -Scope Script -Force
$script:VMConnectSettleSeconds = 3.0
$script:States = @('pending')
$script:StateIndex = 0
$script:StateCalls = 0
$script:SleepCalls = 0
function Set-VMConnectInvokerStates {
    param([string[]]$States)
    $script:States = $States
    $script:StateIndex = 0
    $script:StateCalls = 0
    $script:SleepCalls = 0
}
function Get-VMConnectInvokerCallCount { $script:StateCalls }
function Get-VMConnectInvokerSleepCount { $script:SleepCalls }
function Get-VMConnectWindowState {
    param([string]$VMName)
    $script:StateCalls++
    $i = [Math]::Min($script:StateIndex, $script:States.Count - 1)
    $script:StateIndex++
    $s = $script:States[$i]
    if ($s -eq 'dialog') { return [pscustomobject]@{ State = 'dialog'; Handle = [IntPtr]::new(12345) } }
    return [pscustomobject]@{ State = $s; Handle = [IntPtr]::Zero }
}
function Start-Sleep { param($Seconds, $Milliseconds) $script:SleepCalls++ }
'@
                $moduleSource = $scaffold + "`n" + $text + "`n" +
                    'Export-ModuleMember -Function Resolve-VMConnectAnotherUserDialog, Set-VMConnectInvokerStates, Get-VMConnectInvokerCallCount, Get-VMConnectInvokerSleepCount'
                $module = New-Module -Name ('VMConnectInvokerFixture' + [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($moduleSource))
                Import-Module $module -Force -Global
                return $module
            }

            $script:Invoker = New-VMConnectInvoker
        }
        AfterAll {
            if ($script:Invoker) { Remove-Module -ModuleInfo $script:Invoker -Force -ErrorAction SilentlyContinue }
        }

        It 'dismisses a dialog that appears after two pending observations' {
            Set-VMConnectInvokerStates -States @('pending', 'pending', 'dialog')
            $result = Resolve-VMConnectAnotherUserDialog -VMName 'fixture-vm' -TimeoutSeconds 8
            $result | Should -BeTrue
        }

        It 'returns $false after exactly settle/0.25 consecutive ready observations' {
            Set-VMConnectInvokerStates -States @('ready')
            $result = Resolve-VMConnectAnotherUserDialog -VMName 'fixture-vm' -TimeoutSeconds 8
            $result | Should -BeFalse
            Get-VMConnectInvokerCallCount | Should -Be 12 -Because '3.0 s / 0.25 s = 12 observations'
        }

        It 'still dismisses a dialog that appears late, after the window looked ready' {
            Set-VMConnectInvokerStates -States @('ready', 'ready', 'dialog')
            $result = Resolve-VMConnectAnotherUserDialog -VMName 'fixture-vm' -TimeoutSeconds 8
            $result | Should -BeTrue
            Get-VMConnectInvokerCallCount | Should -Be 3
        }

        It 'restarts the ready streak when a pending observation breaks it' {
            Set-VMConnectInvokerStates -States @('ready', 'ready', 'pending', 'ready', 'ready', 'ready', 'ready', 'ready', 'ready', 'ready', 'ready', 'ready', 'ready', 'ready', 'ready')
            $result = Resolve-VMConnectAnotherUserDialog -VMName 'fixture-vm' -TimeoutSeconds 8
            $result | Should -BeFalse
            Get-VMConnectInvokerCallCount | Should -Be 15 -Because '2 ready + 1 reset + 12 fresh ready observations; a count of 12 would mean the reset never happened'
        }

        It 'returns $false at the deadline when the window never settles or shows a dialog' {
            Set-VMConnectInvokerStates -States @('pending')
            $result = Resolve-VMConnectAnotherUserDialog -VMName 'fixture-vm' -TimeoutSeconds 1
            $result | Should -BeFalse
        }

        It 'never calls the real Start-Sleep' {
            Set-VMConnectInvokerStates -States @('pending', 'pending', 'dialog')
            $null = Resolve-VMConnectAnotherUserDialog -VMName 'fixture-vm' -TimeoutSeconds 8
            Get-VMConnectInvokerSleepCount | Should -BeGreaterThan 0 -Because 'the function still sleeps between polls -- just through the stub, not a real desktop wait'
        }
    }
}
