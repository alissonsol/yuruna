<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42b6904c-f865-423b-822a-edb5cb5994fe
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh virtualization rung repair
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


# Host-refresh repair-ladder declaration. Deliberately holds no driver
# import: the generated status-server child advertises this declaration to
# the UI through Import-RouteModule without ever calling Initialize-
# YurunaHost, and loading a driver there would force-import Test
# .CachingProxyService and run that driver's contract-coverage check inside
# the listener process. Get-VirtualizationRepairRung is therefore a pure,
# host-type-keyed table, not a driver verb -- it lives outside host/Yuruna
# .Host.Contract.psm1's shared surface on purpose.

function Get-VirtualizationRepairRung {
    <#
    .SYNOPSIS
        The complete repair ladder for HostType, as a pure declaration.
    .DESCRIPTION
        Every row is returned, including every currently-unavailable rung:
        an unavailable rung is recorded and skipped, not omitted, so a
        caller (and the UI) can always show the whole ladder and why each
        rung above the caller's ceiling is closed. Available reflects only
        static facts -- which platform this is, and whether the capability
        this rung needs has actually been built and tested in this repo --
        never a live runtime probe; dynamic prerequisites (is the runner
        actually dead right now, is a GUI session actually present) are
        resolved by the worker at the moment it climbs the ladder, not
        here.

        Ordered numerically (0 lowest); Order is what -MaxRung compares
        against, never the string Name.
    .PARAMETER HostType
        The long form ("host.macos.utm", "host.ubuntu.kvm",
        "host.windows.hyper-v") that Get-HostType returns.
    .OUTPUTS
        [pscustomobject[]] one row per rung: @{ Name; Order; Destructive;
        RequiresElevation; RequiresSession; EstimatedSeconds; Available;
        UnavailableReason }.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('host.macos.utm', 'host.ubuntu.kvm', 'host.windows.hyper-v')]
        [string]$HostType
    )

    function New-YurunaRepairRung {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][int]$Order,
            [Parameter(Mandatory)][bool]$Destructive,
            [Parameter(Mandatory)][bool]$RequiresElevation,
            [Parameter(Mandatory)][bool]$RequiresSession,
            [Parameter(Mandatory)][int]$EstimatedSeconds,
            [Parameter(Mandatory)][bool]$Available,
            [AllowNull()][string]$UnavailableReason
        )
        [pscustomobject]@{
            Name              = $Name
            Order             = $Order
            Destructive       = $Destructive
            RequiresElevation = $RequiresElevation
            RequiresSession   = $RequiresSession
            EstimatedSeconds  = $EstimatedSeconds
            Available         = $Available
            UnavailableReason = $UnavailableReason
        }
    }

    $common = @(
        # Rung 0: a bounded, read-only control-channel round-trip
        # (Test-VirtualizationResponsive on every platform). Never
        # destructive, never needs elevation or a GUI session.
        (New-YurunaRepairRung -Name 'probe' -Order 0 -Destructive $false `
            -RequiresElevation $false -RequiresSession $false -EstimatedSeconds 5 `
            -Available $true -UnavailableReason $null)
    )

    switch ($HostType) {
        'host.macos.utm' {
            return @(
                $common
                (New-YurunaRepairRung -Name 'reclaim' -Order 1 -Destructive $false `
                    -RequiresElevation $false -RequiresSession $false -EstimatedSeconds 30 `
                    -Available $true -UnavailableReason $null)
                (New-YurunaRepairRung -Name 'start-if-stopped' -Order 2 -Destructive $false `
                    -RequiresElevation $false -RequiresSession $true -EstimatedSeconds 60 `
                    -Available $true -UnavailableReason $null)
                (New-YurunaRepairRung -Name 'restart-if-hung' -Order 3 -Destructive $true `
                    -RequiresElevation $false -RequiresSession $true -EstimatedSeconds 120 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_62623b0d8a914893'))
                (New-YurunaRepairRung -Name 'restart-broker' -Order 4 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $true -EstimatedSeconds 60 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_f669f22210b44d93'))
                (New-YurunaRepairRung -Name 'reapply-settings' -Order 5 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $true -EstimatedSeconds 300 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_43e526c4ec3b14eb'))
                (New-YurunaRepairRung -Name 'reinstall' -Order 6 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $true -EstimatedSeconds 900 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_7dd6240c15d45471'))
                (New-YurunaRepairRung -Name 'reboot' -Order 7 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 300 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_24aa5f00a8cd0037'))
            )
        }
        'host.ubuntu.kvm' {
            return @(
                $common
                (New-YurunaRepairRung -Name 'reclaim' -Order 1 -Destructive $false `
                    -RequiresElevation $false -RequiresSession $false -EstimatedSeconds 30 `
                    -Available $true -UnavailableReason $null)
                (New-YurunaRepairRung -Name 'start-if-stopped' -Order 2 -Destructive $false `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 30 `
                    -Available $true -UnavailableReason $null)
                (New-YurunaRepairRung -Name 'restart-if-hung' -Order 3 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 60 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_28f2c58cec967f94'))
                (New-YurunaRepairRung -Name 'restart-broker' -Order 4 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 30 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_c3450b84a855bad6'))
                (New-YurunaRepairRung -Name 'reapply-settings' -Order 5 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 120 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_7747dc14e2089beb'))
                (New-YurunaRepairRung -Name 'reinstall' -Order 6 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 900 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_d38c137cc75cebe4'))
                (New-YurunaRepairRung -Name 'reboot' -Order 7 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 300 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_24aa5f00a8cd0037'))
            )
        }
        'host.windows.hyper-v' {
            return @(
                $common
                (New-YurunaRepairRung -Name 'reclaim' -Order 1 -Destructive $false `
                    -RequiresElevation $false -RequiresSession $false -EstimatedSeconds 30 `
                    -Available $true -UnavailableReason $null)
                (New-YurunaRepairRung -Name 'start-if-stopped' -Order 2 -Destructive $false `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 60 `
                    -Available $true -UnavailableReason $null)
                (New-YurunaRepairRung -Name 'restart-if-hung' -Order 3 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 120 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_dcc1cf1dcee82cd5'))
                (New-YurunaRepairRung -Name 'restart-broker' -Order 4 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 30 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_d38c137cc75cebe4'))
                (New-YurunaRepairRung -Name 'reapply-settings' -Order 5 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 120 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_c3f2e879d98b84de'))
                (New-YurunaRepairRung -Name 'reinstall' -Order 6 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 900 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_d38c137cc75cebe4'))
                (New-YurunaRepairRung -Name 'reboot' -Order 7 -Destructive $true `
                    -RequiresElevation $true -RequiresSession $false -EstimatedSeconds 300 `
                    -Available $false -UnavailableReason (Format-YurunaOperatorMessage -Key 'runner.operator_24aa5f00a8cd0037'))
            )
        }
    }
}

Export-ModuleMember -Function Get-VirtualizationRepairRung
