<#PSScriptInfo
.VERSION 2026.09.13
.GUID 420cd1af-0555-401a-9098-1c8630bba45a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test lab health gate hold pester
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
    The lab-health gate: what arms a hold, what releases it, and what it must
    never do.
.DESCRIPTION
    Every property here fails silently in production, which is why each is
    pinned rather than left to the gate's own logs.

    The arming rule is the whole design. A service this host has NEVER reached
    must not hold: a fresh host would park on its first cycle forever, where the
    caller's own pre-flight gives a fast and accurate "there is no stash here".
    A service reached inside the window MUST hold, and that record is read
    across cycles -- a service stopped for a rebuild is already gone when the
    next cycle starts, so a cycle-scoped baseline would never see the transition
    the gate exists to catch.

    The two flag files must stay separate. The auto-release deletes the flag it
    raised; if that were the operator's control.step-pause, a service coming
    back would un-pause a cycle its operator had deliberately parked.

    The ceiling has to be a ceiling. A config asking for more than the compiled
    999 gets 999, or the reasoning behind the number ("about sixteen hours")
    stops being true.

    Probing is mocked at Resolve-LabHealthAddress / Invoke-LabHealthProbe --
    module-internal by design, so the seam is the two functions that touch the
    network and nothing above them is stubbed out.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.LabHealth.psm1') -Force -DisableNameChecking

# The module reaches Send-CycleEventSafely and Write-CycleInfraFailure through
# Get-Command, and a module's command lookup falls back to the GLOBAL session
# state -- not to this file's script scope -- so the stubs have to be global
# functions to be found at all. That is the same resolution path a real cycle
# uses.
#
# What they collect is appended to files in the per-test runtime dir rather than
# to a global variable: the collection then has the same lifetime as the
# directory an It block already creates and deletes, so no state survives a test
# to color the next one.
function global:Send-CycleEventSafely {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test stub standing in for append-only telemetry; no destructive operation.')]
    param([Parameter(Mandatory)][hashtable]$EventRecord)
    Add-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'lh-events.ndjson') `
        -Value ($EventRecord | ConvertTo-Json -Depth 6 -Compress)
}

function global:Write-CycleInfraFailure {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test stub standing in for the failure-record writer; appends to a throwaway file.')]
    param(
        [string]$Stage, [string]$FailureClass, [string]$Severity,
        [string]$GuestKey, [string]$VMName, [string]$ErrorMessage, [string]$HostType
    )
    Add-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'lh-failures.ndjson') -Value (@{
        Stage = $Stage; FailureClass = $FailureClass; Severity = $Severity
        GuestKey = $GuestKey; VMName = $VMName; ErrorMessage = $ErrorMessage; HostType = $HostType
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Get-LhCollected {
    <#
    .SYNOPSIS
        Records the stubs above appended during the current It block.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]], [object[]])]
    param([ValidateSet('events','failures')][string]$Kind = 'events')
    $file = Join-Path $env:YURUNA_RUNTIME_DIR "lh-$Kind.ndjson"
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    return @(Get-Content -LiteralPath $file | Where-Object { $_ } |
        ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
}

function New-LhTempDir {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway runtime dir the calling It block deletes in its finally.')]
    param()
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-lh-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

# One synthetic area, so the assertions do not move when a real extension area
# gains or loses a health surface.
function New-LhManifest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory builder: returns a fresh hashtable; changes no externally observable state.')]
    param([string]$Area = 'stash-service', [string]$DisplayName = 'Stash service')
    return @{
        Area = $Area; DisplayName = $DisplayName; VMName = "yuruna-$Area"; HostedIn = ''
        HealthPort = 80; HealthPath = '/healthz'; StartScript = ''; StopScript = ''
        MarkerBaseUrlKey = ''; BeaconInterval = ''; WriteGate = 'lab-token'
    }
}

function New-LhConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory builder: returns a fresh hashtable; changes no externally observable state.')]
    param([int]$MaxHold = 3, [int]$ArmHours = 24, [int]$MinInterval = 30, [bool]$Enabled = $true)
    return @{ testCycle = @{ labHealth = @{
        enabled = $Enabled; minIntervalSeconds = $MinInterval
        discoveryIntervalSeconds = 600; armWindowHours = $ArmHours
        maxHoldAttempts = $MaxHold; require = @()
    } } }
}

function Set-LhRecord {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([string]$RuntimeDir, [int]$AgeHours = 1, [string]$Address = '10.0.0.9', [string]$Area = 'stash-service')
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, 'seed the lab-health record')) { return }
    $stamp = [datetime]::UtcNow.AddHours(-1 * $AgeHours).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $null = Save-LabHealthRecord -RuntimeDir $RuntimeDir -Confirm:$false -Record @{
        $Area = @{ lastOkUtc = $stamp; lastAddress = $Address; verdict = 'ok' }
    }
}
}

Describe 'Lab-health gate' {

    BeforeEach {
        $script:dir = New-LhTempDir
        $env:YURUNA_RUNTIME_DIR = $script:dir
        Clear-LabHealthVerdictCache -Confirm:$false
        # Every hold test would otherwise sit through the real 59 s-capped
        # backoff; the cadence itself is asserted separately against Get-PollDelay.
        Mock -ModuleName Test.LabHealth Get-LabHoldPollDelay { 1 }
        Mock -ModuleName Test.LabHealth Get-LabHealthProbeSet { @((New-LhManifest)) }
    }

    AfterEach {
        if ($script:dir -and (Test-Path -LiteralPath $script:dir)) {
            Remove-Item -Recurse -Force -LiteralPath $script:dir -ErrorAction SilentlyContinue
        }
        $env:YURUNA_RUNTIME_DIR = $null
    }

    Context 'Arming -- a hold needs a change of condition' {

        It 'never holds for a service this host has never reached' {
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            $v = Test-LabHealth -Config (New-LhConfig) -Force
            $v.Verdict | Should -Be 'ok'
            $v.Down.Count | Should -Be 0

            $r = Wait-LabHealthy -Label '[1/1]' -Config (New-LhConfig) -NoSleep
            $r.Held | Should -BeFalse
            (Test-Path (Get-LabHoldPath).Flag) | Should -BeFalse
        }

        It 'holds for a service reached inside the arming window' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            $v = Test-LabHealth -Config (New-LhConfig) -Force
            $v.Verdict | Should -Be 'down'
            $v.Down[0].area | Should -Be 'stash-service'
            $v.Down[0].lastAddress | Should -Be '10.0.0.9'
        }

        It 'stops holding once the record ages past armWindowHours' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 48 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            (Test-LabHealth -Config (New-LhConfig -ArmHours 24) -Force).Verdict | Should -Be 'ok'
        }

        It 'reads the record across cycles, which is what catches a service stopped before the cycle began' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 2 -Confirm:$false
            # A fresh process: nothing in memory, only the file a previous cycle left.
            Clear-LabHealthVerdictCache -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @() }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            (Test-LabHealth -Config (New-LhConfig) -Force).Verdict | Should -Be 'down'
        }
    }

    Context 'The hold loop' {

        It 'raises the flag and sidecar, then clears both when the service returns' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            $script:calls = 0
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe {
                $script:calls++
                # Two evaluations park the cycle (probe + confirmation), one more
                # fails, and the fourth answers.
                return ($script:calls -ge 4)
            }

            $r = Wait-LabHealthy -Label '[3/14]' -Config (New-LhConfig -MaxHold 10)
            $r.Held    | Should -BeTrue
            $r.Outcome | Should -Be 'recovered'
            $r.Attempts | Should -BeGreaterThan 0

            $paths = Get-LabHoldPath
            (Test-Path $paths.Flag)    | Should -BeFalse
            (Test-Path $paths.Sidecar) | Should -BeFalse
            # Knowledge survives the hold; parked state does not.
            (Test-Path (Join-Path $script:dir 'lab-health.json')) | Should -BeTrue

            $names = @(Get-LhCollected -Kind events | ForEach-Object { $_.event })
            $names | Should -Contain 'lab_health_change'
            $changes = @(Get-LhCollected -Kind events | Where-Object { $_.event -eq 'lab_health_change' })
            $changes.Count | Should -Be 2
            $changes[0].toVerdict | Should -Be 'down'
            $changes[1].toVerdict | Should -Be 'ok'
            $changes[1].heldSeconds | Should -BeGreaterOrEqual 0
        }

        It 'writes a sidecar naming the area and its last known address while held' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Address '192.168.7.61' -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @() }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            $sidecar = ''
            Mock -ModuleName Test.LabHealth Get-LabHoldPollDelay {
                # Read the sidecar from INSIDE the hold, the only moment it exists.
                $script:seen = Get-Content -Raw -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'lab-hold.json')
                return 1
            }
            $null = Wait-LabHealthy -Label '[1/1]' -Config (New-LhConfig -MaxHold 1)
            $sidecar = $script:seen
            $sidecar | Should -Not -BeNullOrEmpty
            $doc = $sidecar | ConvertFrom-Json -AsHashtable
            $doc.areas[0].area        | Should -Be 'stash-service'
            $doc.areas[0].displayName | Should -Be 'Stash service'
            $doc.areas[0].lastAddress | Should -Be '192.168.7.61'
        }

        It 'finds a rebuilt service that came back on a different address' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Address '10.0.0.9' -Confirm:$false
            # Discovery answers with the NEW address only; the old one is gone.
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.44') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe {
                param([string]$Address)
                # The corpse never answers again; the replacement always does.
                return ($Address -eq '10.0.0.44' -and $script:allowNew)
            }
            $script:allowNew = $false
            Mock -ModuleName Test.LabHealth Get-LabHoldPollDelay { $script:allowNew = $true; return 1 }

            $r = Wait-LabHealthy -Label '[1/1]' -Config (New-LhConfig -MaxHold 5)
            $r.Outcome | Should -Be 'recovered'
            (Read-LabHealthRecord)['stash-service'].lastAddress | Should -Be '10.0.0.44'
        }
    }

    Context 'Ending a hold' {

        It 'gives up at the configured ceiling and records lab_dependency_down' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            $caught = $null
            try {
                Invoke-LabHealthGate -Label '[1/11]' -Config (New-LhConfig -MaxHold 2) `
                    -HostType 'host.macos.utm' -Stage 'initialize-lab'
            } catch { $caught = $_ }

            # Tagged as a control-flow marker, not a crash. Both call sites test
            # this to keep their generic crash handler -- which overwrites
            # last_failure.json unconditionally -- off the classified record.
            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Data['YurunaLabDependencyDown'] | Should -BeTrue
            $caught.Exception.Message | Should -BeLike 'YurunaLabDependencyDown:*'

            $failures = @(Get-LhCollected -Kind failures)
            $failures.Count | Should -Be 1
            $failures[0].FailureClass | Should -Be 'lab_dependency_down'
            $failures[0].Severity     | Should -Be 'hard'
            $failures[0].Stage        | Should -Be 'initialize-lab'
            $failures[0].HostType     | Should -Be 'host.macos.utm'
            $failures[0].ErrorMessage | Should -Match 'Stash service'

            @(Get-LhCollected -Kind events | Where-Object { $_.event -eq 'lab_health_exhausted' }).Count | Should -Be 1
            # The hold must not outlive the cycle that raised it.
            (Test-Path (Get-LabHoldPath).Flag) | Should -BeFalse
        }

        It 'stops waiting when the operator requests a release' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }
            Mock -ModuleName Test.LabHealth Get-LabHoldPollDelay {
                Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'control.lab-hold-release') -Value 'x'
                return 1
            }

            $r = Wait-LabHealthy -Label '[1/1]' -Config (New-LhConfig -MaxHold 50)
            $r.Outcome | Should -Be 'released'
            $paths = Get-LabHoldPath
            (Test-Path $paths.Flag)    | Should -BeFalse
            (Test-Path $paths.Release) | Should -BeFalse
            @(Get-LhCollected -Kind events | Where-Object { $_.event -eq 'lab_health_released' }).Count | Should -Be 1
        }

        It 'lets the caller abort a held cycle' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            $abort = {
                param([string]$Label)
                $e = [System.Management.Automation.RuntimeException]::new("YurunaCycleRestart: abort at $Label")
                $e.Data['YurunaCycleRestart'] = $true
                throw $e
            }
            { Wait-LabHealthy -Label '[1/1]' -Config (New-LhConfig -MaxHold 50) -CheckAbort $abort -NoSleep } |
                Should -Throw -ExpectedMessage 'YurunaCycleRestart*'
        }
    }

    Context 'Living beside the operator pause' {

        It 'yields to the operator pause instead of re-probing under it' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            $script:pauseWaits = 0
            $pause = { param([string]$Label) $script:pauseLabel = $Label; $script:pauseWaits++ }
            $r = Wait-LabHealthy -Label '[1/1]' -Config (New-LhConfig -MaxHold 2) -WaitWhilePaused $pause -NoSleep
            $r.Outcome | Should -Be 'exhausted'
            $script:pauseWaits | Should -BeGreaterThan 0
            $script:pauseLabel | Should -Match 'lab hold'
        }

        It 'raises its own flag, never the operator step-pause flag' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @() }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }
            # The operator's pause, set before the hold and untouched by it.
            $stepPause = Join-Path $script:dir 'control.step-pause'
            Set-Content -LiteralPath $stepPause -Value 'operator'

            $null = Wait-LabHealthy -Label '[1/1]' -Config (New-LhConfig -MaxHold 1) -NoSleep
            (Test-Path $stepPause) | Should -BeTrue
            (Test-Path (Get-LabHoldPath).Flag) | Should -BeFalse
        }
    }

    Context 'Cost of running at every step boundary' {

        It 'answers from cache inside minIntervalSeconds and re-probes after it' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $true }

            $null = Test-LabHealth -Config (New-LhConfig -MinInterval 30)
            $null = Test-LabHealth -Config (New-LhConfig -MinInterval 30)
            $null = Test-LabHealth -Config (New-LhConfig -MinInterval 30)
            Should -Invoke Invoke-LabHealthProbe -ModuleName Test.LabHealth -Times 1 -Exactly

            # Past the freshness window the verdict is asked again.
            $later = [datetime]::UtcNow.AddSeconds(31)
            $null = Test-LabHealth -Config (New-LhConfig -MinInterval 30) -NowUtc $later
            Should -Invoke Invoke-LabHealthProbe -ModuleName Test.LabHealth -Times 2 -Exactly
        }

        It 'probes the last known address first, without asking discovery' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Address '10.0.0.9' -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $true }

            (Test-LabHealth -Config (New-LhConfig) -Force).Verdict | Should -Be 'ok'
            Should -Invoke Resolve-LabHealthAddress -ModuleName Test.LabHealth -Times 0 -Exactly
        }
    }

    Context 'The call sites recognize the marker' {

        # Both gate sites sit in front of a generic handler that would undo the
        # gate's work -- the engine's crash path overwrites last_failure.json
        # unconditionally, and the orchestrator's enclosing construct is
        # try/finally with no catch, so an escaping throw finalizes the cycle
        # with whatever $overall held. Neither is reachable from a unit test, so
        # the branch that prevents each is pinned against the source.

        It 'the sequence engine handles the marker before its crash record' {
            $src = Get-Content -Raw -LiteralPath (Join-Path $here 'Test.SequenceEngine.psm1')
            $marker = $src.IndexOf("YurunaLabDependencyDown")
            $crash  = $src.IndexOf("New-SequenceFailureRecord -Reason 'crash'")
            $marker | Should -BeGreaterThan 0
            $crash  | Should -BeGreaterThan 0
            $marker | Should -BeLessThan $crash
        }

        It 'the orchestrator fails the entry instead of escaping its finalizer' {
            $src = Get-Content -Raw -LiteralPath (Join-Path $here 'Test.Orchestrator.psm1')
            $src | Should -Match 'labHoldReason'
            # The cycle-restart marker must keep escaping: unwinding is what it asks for.
            $src | Should -Match "YurunaCycleRestart:\*'\)\) \{ throw \}"
        }

        It 'both gate sites call through Invoke-LabHealthGate' {
            foreach ($f in @('Test.SequenceEngine.psm1', 'Test.Orchestrator.psm1')) {
                (Get-Content -Raw -LiteralPath (Join-Path $here $f)) | Should -Match 'Invoke-LabHealthGate'
            }
        }
    }

    Context 'Configuration' {

        It 'clamps maxHoldAttempts to the compiled ceiling' {
            (Get-LabHealthConfig -Config (New-LhConfig -MaxHold 5000)).MaxHoldAttempts |
                Should -Be (Get-LabHealthHoldCeiling)
            Get-LabHealthHoldCeiling | Should -Be 999
        }

        It 'clamps a maxHoldAttempts below one up to one' {
            (Get-LabHealthConfig -Config (New-LhConfig -MaxHold -4)).MaxHoldAttempts | Should -Be 1
        }

        It 'reads an absent block as enabled' {
            (Get-LabHealthConfig -Config @{}).Enabled | Should -BeTrue
            (Get-LabHealthConfig -Config $null).Enabled | Should -BeTrue
        }

        It 'does not hold at all when disabled' {
            Set-LhRecord -RuntimeDir $script:dir -AgeHours 1 -Confirm:$false
            Mock -ModuleName Test.LabHealth Resolve-LabHealthAddress { @('10.0.0.9') }
            Mock -ModuleName Test.LabHealth Invoke-LabHealthProbe { $false }

            $r = Wait-LabHealthy -Label '[1/1]' -Config (New-LhConfig -Enabled $false) -NoSleep
            $r.Held | Should -BeFalse
            Should -Invoke Invoke-LabHealthProbe -ModuleName Test.LabHealth -Times 0 -Exactly
        }
    }
}
