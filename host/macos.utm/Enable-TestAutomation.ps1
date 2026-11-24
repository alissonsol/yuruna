<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42ff1bc2-5f12-4c34-8a53-a45f6186f94f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host macos utm enable-test-automation
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
    Prepares the macOS UTM host to run yuruna automated VM tests.

.DESCRIPTION
    Captures the host's original settings once, then applies the platform's
    unattended-test prerequisites and optional pool-storage setup. Re-running
    preserves the original capture used by Disable-TestAutomation.ps1.
    See https://yuruna.link/42e220c4-0004 and https://yuruna.link/42885ada-0001.
    Run without sudo. Individual privileged changes announce their requirements;
    macOS privacy grants and the account password still require the operator.

    It also deploys the host controller (its shim and a snapshot of this
    checkout under ~/.yuruna/host-repair/host-controller) and installs the
    sudoers entry /etc/sudoers.d/yuruna-host-update-access, which lets the
    controller write and remove the temporary rule of a full host update. No
    job is registered: an ordinary runner start from a terminal of the desktop
    session starts the controller. When the shim changed, an idle controller
    session is ended so the next runner start starts the new one. A session
    left running because it may run a host update, or that could not be
    ended, is ended by a later run once it is idle.

    Exit 2 means some settings still need operator attention. Exit 1 means the
    run failed, or -NoOperatorPrompt refused before capturing or changing
    anything.

.PARAMETER SkipPoolStorage
    Settings-only run: skip the interactive networkStorage questionnaire at the
    end. install/setup.ps1 configures storage itself, in its own order, and
    would otherwise ask the same questions twice.

.PARAMETER NoOperatorPrompt
    Apply the settings with nobody at the keyboard. Nothing is asked and
    nothing disrupts the desktop session: no consent dialog, no Dock or screen
    saver restart, no PSGallery install, no sudo password prompt and no
    networkStorage questionnaire (it implies -SkipPoolStorage). A setting that
    needs one of those is left for an operator and counted as unmet (exit 2)
    instead of being asked for. YURUNA_NONINTERACTIVE is 1 for this script's
    lifetime and restored afterwards.

    The host controller is only verified (the deployed shim is this
    checkout's and current names a snapshot), never deployed, and the
    sudoers entry is never installed: a host update runs this mode, and its
    controller is the one a deployment would replace. A difference is
    counted as unmet.

    Refuses with exit 1, before capturing or changing anything, when the loaded
    Set-MacHostConditionSet cannot run without disrupting the desktop session
    (it has no -NoGuiDisruption), or when -Confirm asks for a prompt before each
    change.

    YURUNA_NONINTERACTIVE alone is not this switch: install/setup.ps1 runs this
    script with that variable set and still expects the consent dialogs, which
    are raised because an operator is present to answer them.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    ./Enable-TestAutomation.ps1
    ./Enable-TestAutomation.ps1 -WhatIf
    ./Enable-TestAutomation.ps1 -NoOperatorPrompt
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipPoolStorage,
    [switch]$NoOperatorPrompt
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = "Stop"

# Surface the module's action-taken messages (Set-MacHostConditionSet
# reports each setting via Write-Information). Without Continue, the
# display-sleep / screen-lock / hot-corner / Spaces decisions print
# nothing and the operator can't tell what changed.
$InformationPreference = 'Continue'

# No platform guard, unlike the sibling hosts: Test.HostSettingsNoPrompt runs
# this file byte for byte on every host with the macOS-only modules stubbed,
# and an $IsMacOS check would end that coverage off a Mac.

# Captured before anything below can change it: the finally block puts the
# caller's value back, or removes the variable when the caller had none, so an
# in-process caller does not inherit this run's no-prompt mode.
$savedNonInteractive = [Environment]::GetEnvironmentVariable('YURUNA_NONINTERACTIVE')
$exitCode = 0
$unmetCount = 0
try {
    # --- REGION: No-prompt mode
    # -NoOperatorPrompt is a promise made before anything runs, so each thing
    # that would break it is settled here, and a refusal exits before the
    # capture or any setting is touched. -Confirm is the caller asking for a
    # prompt per change, the opposite request; honoring either one silently
    # would be wrong, so the combination refuses.
    $noPromptArgs = @{}
    if ($NoOperatorPrompt) {
        if ($PSBoundParameters.ContainsKey('Confirm') -and [bool]$PSBoundParameters['Confirm']) {
            Write-Error -Message (Format-YurunaOperatorMessage -Key 'host.enable_automation_no_prompt_confirm_conflict') -ErrorAction Continue
            exit 1
        }
        # Every prompt predicate in the modules this run loads, and every child
        # it starts, reads the environment rather than a parameter.
        $env:YURUNA_NONINTERACTIVE = '1'
        # A module function reads the global $ConfirmPreference, not this
        # script's, so a low value inherited from the session could still prompt
        # at the default impact. -Confirm:$false on each ShouldProcess call below
        # binds inside the callee and closes that path.
        $ConfirmPreference = 'None'
        $noPromptArgs['Confirm'] = $false
    }

    # --- REGION: Initialize host setup
    # See https://yuruna.link/42e5cdfd-000b
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
    if ($NoOperatorPrompt) {
        Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters -SkipModuleInstall @noPromptArgs
    } else {
        Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters -SudoCacheReason @(
            'pmset (display sleep, system sleep, power-nap, hibernation)',
            'defaults write /Library/Preferences (auto-logout delay)',
            'sysadminctl -screenLock off (Sonoma+ unified screen lock)',
            'systemsetup -setusingnetworktime + sntp -sS (host clock discipline)',
            'ln -s into /usr/local/bin (utmctl, the UTM command line, on PATH)',
            'install /etc/sudoers.d/yuruna-host-update-access (the host update elevation entry)'
        )
    }
    # Feature-detected on the command that will actually run, not assumed from
    # this file's age: a checkout whose host-condition module predates
    # -NoGuiDisruption would restart the Dock and raise consent dialogs, which
    # is exactly what this mode promised not to do. The mode is announced only
    # once it is known to be available, so a refused run never claims it.
    if ($NoOperatorPrompt) {
        $conditionCommand = Get-Command -Name 'Set-MacHostConditionSet' -ErrorAction SilentlyContinue
        if (-not $conditionCommand -or -not $conditionCommand.Parameters.ContainsKey('NoGuiDisruption')) {
            Write-Error -Message (Format-YurunaOperatorMessage -Key 'host.enable_automation_no_prompt_unsupported') -ErrorAction Continue
            exit 1
        }
        Write-Information (Format-YurunaOperatorMessage -Key 'host.enable_automation_no_prompt_mode')
    }

    # --- REGION: Pre-automation capture
    # BEFORE anything is changed: record what these knobs were, so
    # Disable-TestAutomation can put them back. Written once and never overwritten
    # -- a second Enable must not capture Enable's own values as the operator's.
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
    $capturePath = Save-HostAutomationState -Platform 'macos.utm' -WhatIf:$WhatIfPreference @noPromptArgs
    if ($capturePath) { Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_18ab1c2a314eaf6a' -Arguments @{ capturePath = "$capturePath" }) }

    # --- REGION: Host update elevation entry
    # The full scope of a host update needs root for its install and enable
    # phases, and macOS has no passwordless manifest. The entry lets the test
    # account write and remove the temporary rule's file, and nothing else.
    # It is Yuruna's own file, replaced when its text differs. It is
    # installed here, with the credential primed above, because the grant
    # assist below can wait on the operator longer than macOS keeps it.
    # -NoOperatorPrompt never installs it. A module imported inside another
    # one is not visible here, so each module this script calls is imported
    # by name.
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.SingleFlightLock.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostOperationJournal.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostUpdate.psm1') -Force -DisableNameChecking
    if (-not $NoOperatorPrompt -and -not $WhatIfPreference) {
        $accessEntry = Install-HostUpdateAccessEntry -Account ([Environment]::UserName) -Confirm:$false
        if ($accessEntry.Reason -in @('installed', 'replaced', 'unchanged')) {
            Write-Output (Format-YurunaOperatorMessage -Key "host.host_update_access_entry_$($accessEntry.Reason)")
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_update_access_entry_failed' -Arguments @{ detail = "$($accessEntry.Detail)" })
            $unmetCount++
        }
    }

    # --- REGION: Host condition set
    # -SkipPoolStorage and -NoOperatorPrompt are ours, not
    # Set-MacHostConditionSet's; splatting them through would fail parameter
    # binding. The no-prompt mode maps onto the module's own switch instead.
    $conditionArgs = @{}
    foreach ($k in $PSBoundParameters.Keys) { if ($k -notin @('SkipPoolStorage', 'NoOperatorPrompt')) { $conditionArgs[$k] = $PSBoundParameters[$k] } }
    if ($NoOperatorPrompt) {
        $conditionArgs['NoGuiDisruption'] = $true
        $conditionArgs['Confirm'] = $false
    }
    # Select the count out of whatever came back rather than casting the lot.
    # Set-MacHostConditionSet shells out to pmset, defaults and sysadminctl, and one
    # uncaptured line from any of them would make its return an array -- which a
    # straight [int] cast turns into a thrown error, converting a cosmetic leak into
    # a failed setup step.
    $conditionResult = @(Set-MacHostConditionSet @conditionArgs)
    $conditionUnmet = @($conditionResult | Where-Object { $_ -is [int] } | Select-Object -Last 1)
    if ($conditionUnmet.Count) { $unmetCount += [int]$conditionUnmet[0] }

    # --- REGION: Pool storage and host identity
    # See https://yuruna.link/428405a0-0009
    # The no-prompt mode must never reach the interactive questionnaire.
    if ($SkipPoolStorage) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_07d790b607ee2b44')
    } elseif (-not $NoOperatorPrompt -and -not $WhatIfPreference) {
        Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostIdentity.psm1') -Force
        Invoke-PoolStorageSetupAndReclaim -RepoRoot $RepoRoot
    }

    # --- REGION: Host controller
    # See https://yuruna.link/42f909ad-002b
    # macOS registers no job: an ordinary runner start from the desktop
    # session starts the shim in a multiplexer session of its own, so this
    # deploys the shim and the checkout's snapshot and starts nothing.
    # -NoOperatorPrompt runs inside a host update and only verifies.
    if ($NoOperatorPrompt) {
        $deployment = Test-HostUpdateControllerDeployment -RepoRoot $RepoRoot -NoDefinition
        if ($deployment -ne 'ready') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_not_verified' -Arguments @{ reason = "$deployment" })
            $unmetCount++
        }
    } elseif (-not $WhatIfPreference) {
        $files = Install-HostUpdateControllerFile -RepoRoot $RepoRoot -Confirm:$false
        # The snapshot is staged before current is written, so a failure to
        # write current still names one; only these two reasons leave a
        # deployment a runner start can use.
        if ($files.Reason -notin @('installed', 'unchanged')) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_files_failed_macos' -Arguments @{ reason = "$($files.Reason)" })
            $unmetCount++
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'host.host_controller_deployed_macos' -Arguments @{ snapshot = "$($files.Snapshot)" })
            # A running shim keeps the file it started from, so a new shim
            # takes effect only in a new session. An idle session is ended
            # and the next runner start starts the new one; a session whose
            # controller runs a host update, or may run one because the
            # journal cannot be read, is left to finish it. The new shim is
            # already on disk then, so a later run no longer sees it change:
            # the session-restart-pending file beside the shim carries the
            # pending end to that run, until a session end leaves none.
            $pendingPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName([string]$files.Shim), 'session-restart-pending')
            if ($files.ShimChanged -or [System.IO.File]::Exists($pendingPath)) {
                $idle = @('ok', 'absent', 'recovered-previous')
                $queue = Get-HostUpdateQueue
                $pending = $true
                if ($queue.Status -notin $idle) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_session_kept_unknown' -Arguments @{ status = "$($queue.Status)" })
                } elseif ($queue.Claimed) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'host.host_controller_session_kept' -Arguments @{ requestId = "$($queue.Claimed['requestId'])" })
                } else {
                    $session = Stop-HostUpdateControllerSession -Confirm:$false
                    $pending = -not $session.Ended
                    # The controller may have claimed an update between the
                    # read and the end; nothing continues it until a start.
                    if ($session.Reason -eq 'ended') {
                        $queueNow = Get-HostUpdateQueue
                        if ($queueNow.Status -notin $idle) {
                            Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_session_ended_unknown' -Arguments @{ status = "$($queueNow.Status)" })
                        } elseif ($queueNow.Claimed) {
                            Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_session_ended_claimed' -Arguments @{ requestId = "$($queueNow.Claimed['requestId'])" })
                        } else {
                            Write-Output (Format-YurunaOperatorMessage -Key 'host.host_controller_session_restart_pending')
                        }
                    } elseif ($pending) {
                        Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_session_end_failed')
                    }
                }
                try {
                    if ($pending) { [System.IO.File]::WriteAllText($pendingPath, '') } else { [System.IO.File]::Delete($pendingPath) }
                } catch {
                    Write-Verbose "Enable-TestAutomation: '$pendingPath' not updated: $($_.Exception.Message)"
                }
            }
        }
    }

    # --- REGION: Outcome
    # See https://yuruna.link/42e220c4-0004 for the shared 0/1/2 host-setup contract.
    if ($unmetCount -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6661089d0f925ca8' -Arguments @{ unmetCount = "$unmetCount" })
        $exitCode = 2
    }
} finally {
    if ($NoOperatorPrompt) {
        if ($null -eq $savedNonInteractive) {
            Remove-Item -LiteralPath 'Env:YURUNA_NONINTERACTIVE' -ErrorAction SilentlyContinue
        } else {
            $env:YURUNA_NONINTERACTIVE = $savedNonInteractive
        }
    }
}
exit $exitCode
