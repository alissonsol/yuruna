<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42a3f6d1-8e2b-4c57-b9d4-7f1e0c5a6b28
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner hypervisor control gate pester
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
    The pre-cycle hypervisor control gate: it fails a cycle only on a driver
    probe whose lifecycle verb timed out, passes through every other answer
    with its reason, and records the driver's control snapshot beside the
    verdict.
.DESCRIPTION
    The driver's probe and snapshot verbs are stand-ins defined for each
    case, so the gate's policy is tested apart from any hypervisor: which
    answers fail it, what it asks the probe for, and what it leaves behind.
#>
BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.RunnerInnerLoop.psm1') -Force -Global -DisableNameChecking -WarningAction SilentlyContinue
    # The stand-ins are global functions, so their exchange with the test
    # lives in one global bag rather than in a script scope they cannot see.
    function Initialize-GateExchange {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
            Justification = 'Test fixture: the global stand-ins and the test share one global bag.')]
        [CmdletBinding()]
        param()
        $global:YrnGateTest = @{ Record = $null; Throw = ''; ProbeCalls = [System.Collections.Generic.List[hashtable]]::new(); SnapshotCalls = [System.Collections.Generic.List[hashtable]]::new() }
    }
    function Get-GateExchange {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
            Justification = 'Test fixture: reads the bag the global stand-ins write.')]
        [CmdletBinding()]
        param()
        return $global:YrnGateTest
    }
    Initialize-GateExchange
    function Get-ProbeRecord {
        param([string]$State = 'Responsive', [string]$Reason = 'responsive', [string]$LifecycleOutcome = 'responsive', [string]$VMName = 'test-guest-01', [bool]$WithLifecycle = $true)
        $evidence = [ordered]@{ utmctlSource = 'path'; sessionKind = 'Aqua'; appState = 'running'; automationGrant = 'unknown'; exitCode = 0; drainTimedOut = $false; outputTruncated = $false }
        if ($WithLifecycle) {
            $evidence['lifecycle'] = [pscustomobject]@{ attempted = ($LifecycleOutcome -in @('responsive', 'timeout')); verb = 'stop'; vmName = $VMName; outcome = $LifecycleOutcome; exitCode = 0; timedOut = ($LifecycleOutcome -eq 'timeout') }
        }
        return [pscustomobject]@{
            PSTypeName = 'Yuruna.VirtualizationProbe'; schemaVersion = 1; hostType = 'host.macos.utm'
            state = $State; reason = $Reason; started = $true; timedOut = ($Reason -eq 'timeout'); deadlineExhausted = $false
            corroborated = ($State -eq 'Unresponsive'); observedUtc = [DateTime]::UtcNow.ToString('o'); observedTick = 0; elapsedMs = 1
            evidence = [pscustomobject]$evidence; diagnostic = ''; automationSubject = 'uid=501;'; inventory = $null
        }
    }
    function Use-ProbeStub {
        <#
        .SYNOPSIS
            Define the driver's probe verb as a stand-in that records its
            arguments and answers with -Record, or throws -Throw.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
            Justification = 'Test fixture: defines or clears the global stand-ins and the bag they write.')]
        [CmdletBinding()]
        param([AllowNull()]$Record, [string]$Throw = '', [switch]$WithoutLifecycleParameter)
        $global:YrnGateTest.Record = $Record
        $global:YrnGateTest.Throw = $Throw
        if ($WithoutLifecycleParameter) {
            Set-Item -Path 'function:global:Test-VirtualizationResponsive' -Value {
                [CmdletBinding()] param([int]$TimeoutSeconds = 20, $Deadline, [switch]$Corroborate, [int]$DialogWindowSeconds = 120)
                $null = @($Deadline, $Corroborate, $DialogWindowSeconds)
                $global:YrnGateTest.ProbeCalls.Add(@{ TimeoutSeconds = $TimeoutSeconds })
                if ($global:YrnGateTest.Throw) { throw $global:YrnGateTest.Throw }
                return $global:YrnGateTest.Record
            }
        } else {
            Set-Item -Path 'function:global:Test-VirtualizationResponsive' -Value {
                [CmdletBinding()] param([int]$TimeoutSeconds = 20, $Deadline, [switch]$Corroborate, [int]$DialogWindowSeconds = 120, [string[]]$RecordedAutomationSubject = @(), [switch]$IncludeInventory, [switch]$LifecycleProbe, [string[]]$LifecycleProbePrefix = @(), [int]$LifecycleRetryWindowSeconds = 15)
                $null = @($Deadline, $RecordedAutomationSubject, $IncludeInventory, $LifecycleRetryWindowSeconds)
                $global:YrnGateTest.ProbeCalls.Add(@{ TimeoutSeconds = $TimeoutSeconds; LifecycleProbe = [bool]$LifecycleProbe; Prefix = [string[]]$LifecycleProbePrefix; Corroborate = [bool]$Corroborate; DialogWindowSeconds = $DialogWindowSeconds })
                if ($global:YrnGateTest.Throw) { throw $global:YrnGateTest.Throw }
                return $global:YrnGateTest.Record
            }
        }
    }
    function Use-SnapshotStub {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
            Justification = 'Test fixture: defines or clears the global stand-ins and the bag they write.')]
        [CmdletBinding()]
        param()
        Set-Item -Path 'function:global:Save-UtmControlSnapshot' -Value {
            [CmdletBinding(SupportsShouldProcess)] param([string]$OutputDirectory, [string]$Trigger = 'operator', [string]$VMName = '', $Deadline)
            $null = @($OutputDirectory, $Deadline)
            $global:YrnGateTest.SnapshotCalls.Add(@{ Trigger = $Trigger; VMName = $VMName })
            return [pscustomobject]@{ Written = $true; Reason = 'written'; Directory = '/tmp'; Path = '/tmp/utm-control-snapshot.json'; Record = $null }
        }
    }
    function Clear-Stub {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
            Justification = 'Test fixture: defines or clears the global stand-ins and the bag they write.')]
        [CmdletBinding()]
        param()
        # A plain function: path removes the global stand-in from any scope; the
        # global:-qualified path does not.
        foreach ($name in @('Test-VirtualizationResponsive', 'Save-UtmControlSnapshot')) {
            if (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue) { Remove-Item -Path "function:$name" -Force -ErrorAction SilentlyContinue }
        }
        $global:YrnGateTest.ProbeCalls.Clear()
        $global:YrnGateTest.SnapshotCalls.Clear()
        $global:YrnGateTest.Record = $null
        $global:YrnGateTest.Throw = ''
    }
}
AfterAll {
    Clear-Stub
    Remove-Variable -Name YrnGateTest -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Test-RunnerHypervisorControlGate' {
    BeforeEach { Clear-Stub }
    AfterEach { Clear-Stub }

    It 'passes through, unprobed, when the host driver has no probe at all' {
        $r = Test-RunnerHypervisorControlGate -HostType 'host.ubuntu.kvm' -Config $null
        Assert-True $r.Ok
        Assert-False $r.Probed
        Assert-StringEqual 'not-applicable' $r.Reason
    }

    It 'passes through, unprobed, when the probe cannot exercise the lifecycle path' {
        Use-ProbeStub -WithoutLifecycleParameter -Record (Get-ProbeRecord -State 'Unresponsive' -Reason 'timeout' -WithLifecycle:$false)
        $r = Test-RunnerHypervisorControlGate -HostType 'host.windows.hyper-v' -Config @{}
        Assert-True $r.Ok
        Assert-False $r.Probed
        Assert-Equal 0 (Get-GateExchange).ProbeCalls.Count -Because 'a probe without the lifecycle parameter is never asked'
    }

    It 'asks for the lifecycle verb, corroboration and no dialog window, preferring the configured VM prefix' {
        Use-ProbeStub -Record (Get-ProbeRecord)
        $r = Test-RunnerHypervisorControlGate -HostType 'host.macos.utm' -Config @{ vmStart = @{ testVmNamePrefix = 'lab-' } } -TimeoutSeconds 7
        Assert-True $r.Ok
        Assert-True $r.Probed
        Assert-StringEqual 'Responsive/responsive' $r.Reason
        Assert-Equal 1 (Get-GateExchange).ProbeCalls.Count
        $call = (Get-GateExchange).ProbeCalls[0]
        Assert-True $call.LifecycleProbe 'the lifecycle verb was requested'
        Assert-True $call.Corroborate 'one timeout is not a verdict'
        Assert-Equal 0 $call.DialogWindowSeconds -Because 'an answered listing rules the consent dialog out'
        Assert-Equal 7 $call.TimeoutSeconds
        Assert-True ($call.Prefix -contains 'lab-') 'the configured prefix is preferred'
    }

    It 'prefers the default test prefix when the configuration names none' {
        Use-ProbeStub -Record (Get-ProbeRecord)
        $null = Test-RunnerHypervisorControlGate -HostType 'host.macos.utm' -Config $null
        Assert-True ((Get-GateExchange).ProbeCalls[0].Prefix -contains 'test-')
        $null = Test-RunnerHypervisorControlGate -HostType 'host.macos.utm' -Config ([pscustomobject]@{ vmStart = [pscustomobject]@{ testVmNamePrefix = 'obj-' } })
        Assert-True ((Get-GateExchange).ProbeCalls[1].Prefix -contains 'obj-') 'an object-shaped configuration is read too'
    }

    It 'fails the gate on a corroborated lifecycle timeout and records the control snapshot' {
        Use-ProbeStub -Record (Get-ProbeRecord -State 'Unresponsive' -Reason 'timeout' -LifecycleOutcome 'timeout' -VMName 'amisad-build')
        Use-SnapshotStub
        $r = Test-RunnerHypervisorControlGate -HostType 'host.macos.utm' -Config @{}
        Assert-False $r.Ok
        Assert-True $r.Probed
        Assert-StringEqual 'Unresponsive/timeout' $r.Reason
        Assert-Match 'stop amisad-build: timeout' $r.Message 'the verb and the VM it was sent to are named'
        Assert-Match 'Invoke-HostRefresh' $r.Message 'the repair is named'
        Assert-Equal 1 (Get-GateExchange).SnapshotCalls.Count -Because 'the snapshot is taken while the state still exists'
        Assert-StringEqual 'cycle-start-control-gate' (Get-GateExchange).SnapshotCalls[0].Trigger
        Assert-StringEqual 'amisad-build' (Get-GateExchange).SnapshotCalls[0].VMName
        Assert-True $r.Snapshot.Written
    }

    It 'still fails the gate when no snapshot verb exists' {
        Use-ProbeStub -Record (Get-ProbeRecord -State 'Unresponsive' -Reason 'timeout' -LifecycleOutcome 'timeout')
        $r = Test-RunnerHypervisorControlGate -HostType 'host.macos.utm' -Config @{}
        Assert-False $r.Ok
        Assert-Null $r.Snapshot 'nothing to record with'
    }

    It 'names one fault only: <Case> passes with its reason' -TestCases @(
        @{ Case = 'a listing timeout corroborated by a recorded subject'; State = 'Unresponsive'; Reason = 'timeout'; Lifecycle = 'not-attempted' }
        @{ Case = 'the application stopped';                              State = 'Unresponsive'; Reason = 'app-stopped'; Lifecycle = 'not-attempted' }
        @{ Case = 'an uncorroborated lifecycle timeout';                  State = 'Undetermined'; Reason = 'timeout'; Lifecycle = 'timeout' }
        @{ Case = 'a denied automation grant';                            State = 'Undetermined'; Reason = 'permission-denied'; Lifecycle = 'not-attempted' }
        @{ Case = 'no stopped VM to probe';                               State = 'Responsive';   Reason = 'responsive'; Lifecycle = 'skipped-no-stopped-vm' }
    ) {
        param($Case, $State, $Reason, $Lifecycle)
        Use-ProbeStub -Record (Get-ProbeRecord -State $State -Reason $Reason -LifecycleOutcome $Lifecycle)
        Use-SnapshotStub
        $r = Test-RunnerHypervisorControlGate -HostType 'host.macos.utm' -Config @{}
        Assert-True $r.Ok $Case
        Assert-True $r.Probed $Case
        Assert-StringEqual "$State/$Reason" $r.Reason $Case
        Assert-Equal 0 (Get-GateExchange).SnapshotCalls.Count -Because "$Case takes no snapshot"
    }

    It 'passes through when the probe throws, and says so' {
        Use-ProbeStub -Throw 'probe exploded'
        $r = Test-RunnerHypervisorControlGate -HostType 'host.macos.utm' -Config @{}
        Assert-True $r.Ok
        Assert-False $r.Probed
        Assert-Match '^probe-threw: probe exploded' $r.Reason
    }

    It 'passes through when the probe returns nothing' {
        Use-ProbeStub -Record $null
        $r = Test-RunnerHypervisorControlGate -HostType 'host.macos.utm' -Config @{}
        Assert-True $r.Ok
        Assert-StringEqual 'probe-empty' $r.Reason
    }
}

Describe 'The inner cycle wires the gate like the other pre-cycle gates' {
    BeforeAll {
        $script:ModuleText = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.RunnerInnerLoop.psm1')
    }

    It 'runs the gate after the per-cycle module import, where the driver is loaded' {
        $import = $script:ModuleText.IndexOf('Update-CycleModuleImport -RepoRoot $RepoRoot -HostType $HostType -ModulesDir $ModulesDir')
        $gate = $script:ModuleText.IndexOf('$controlGate = Test-RunnerHypervisorControlGate -HostType $HostType -Config $Config')
        Assert-True ($import -ge 0 -and $gate -gt $import) 'the gate follows the import that loads the host driver'
    }

    It 'files the failure as hypervisor_unresponsive through the bootstrap gate and breaks out of the cycle' {
        $block = [regex]::Match($script:ModuleText, '(?s)\$controlGate = Test-RunnerHypervisorControlGate.*?\n\s+break\n\s+\}').Value
        Assert-True ([bool]$block) 'the gate block ends in a break'
        Assert-Match "Write-CycleInfraFailure -Stage 'HypervisorControl' -FailureClass 'hypervisor_unresponsive'" $block
        Assert-Match "Invoke-RunnerBootstrapFailureGate -GatingState \`$controlGateState -Stage 'HypervisorControl'" $block
        Assert-Match '\$OverallPassed = \$false' $block 'a refused cycle is a failed cycle'
    }
}
