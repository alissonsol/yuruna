<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42e290d1-39a7-4b36-900a-015184cc6a36
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna windows installer boot
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

function Start-YurunaWindowsInstaller {
    <#
    .SYNOPSIS
        Start a newly created Windows VM and accept its initial DVD boot prompt.
    .DESCRIPTION
        The start callback must throw on failure and return before waiting for
        a console window. The key callback sends Space directly to the guest
        and returns a boolean indicating transport delivery.

        Firmware can accept a key before the DVD loader displays its prompt,
        so a successful send does not end the burst. Keep sending through the
        boot window, tolerating transient keyboard initialization failures.
        This runs only for a fresh installation; later boots receive no keys.
    .PARAMETER VMName
        The newly created VM whose installer is being started.
    .PARAMETER StartVM
        Host-specific startup callback. Its output is discarded.
    .PARAMETER SendBootKey
        Focus-independent callback that sends Space to this VM's keyboard.
    .PARAMETER BootKeySeconds
        Duration of the initial boot-key burst after the startup call returns.
    .PARAMETER PollMilliseconds
        Interval between boot-key delivery attempts.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][scriptblock]$StartVM,
        [Parameter(Mandatory)][scriptblock]$SendBootKey,
        [ValidateRange(1, 60)][int]$BootKeySeconds = 15,
        [ValidateRange(10, 1000)][int]$PollMilliseconds = 250
    )

    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_5115fc3aa0fb34ef'))) { return }

    $null = & $StartVM
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $windowMilliseconds = [long]$BootKeySeconds * 1000
    $delivered = $false
    do {
        try {
            $result = & $SendBootKey
            # A populated error record or hashtable is truthy in PowerShell;
            # only the transport's explicit boolean confirms key delivery.
            if ($result -is [bool] -and $result) { $delivered = $true }
        } catch {
            Write-Verbose "Boot keyboard for '$VMName' is not ready: $($_.Exception.Message)"
        }
        $remaining = $windowMilliseconds - $clock.ElapsedMilliseconds
        if ($remaining -gt 0) {
            Start-Sleep -Milliseconds ([int][Math]::Min($PollMilliseconds, $remaining))
        }
    } while ($clock.ElapsedMilliseconds -lt $windowMilliseconds)

    if (-not $delivered) {
        throw [TimeoutException]::new((Format-YurunaOperatorMessage -Key 'host.windows_installer_boot_key_timeout' -Arguments @{
            vmName = $VMName; seconds = $BootKeySeconds
        }))
    }
}

Export-ModuleMember -Function Start-YurunaWindowsInstaller
