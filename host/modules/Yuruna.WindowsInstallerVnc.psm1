<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42f99a86-84d2-47d2-b799-684a67d03d08
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna windows installer boot vnc
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

function Start-YurunaWindowsInstallerVnc {
    <#
    .SYNOPSIS
        Arm the Windows DVD boot keyboard before starting a UTM VM.
    .DESCRIPTION
        UTM can power on a VM before its synchronous start request returns.
        A separate runspace loads the VNC transport before startup, then
        accepts the DVD prompt while the startup caller is still waiting.
        Only the VNC port recorded in the bundle is used; a name-derived
        fallback could belong to another running VM before port allocation.
    .PARAMETER StartVM
        Host startup callback, which must throw on failure. Its argument is a
        shared event to set after VNC port allocation and before power-on.
        Output is discarded.
    .PARAMETER ReadyTimeoutSeconds
        Maximum wait for the worker to finish loading its transport.
    .PARAMETER KeyDeliveryTimeoutSeconds
        Backstop while waiting for a first successful key during startup.
        Once startup returns, the worker allows BootKeySeconds for readiness.
    .PARAMETER BootKeySeconds
        Duration of the boot-key burst after the first successful send.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'The worker receives all values and shared synchronization objects through explicit ArgumentList parameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][scriptblock]$StartVM,
        [ValidateRange(1, 120)][int]$ReadyTimeoutSeconds = 30,
        [ValidateRange(1, 1800)][int]$KeyDeliveryTimeoutSeconds = 1200,
        [ValidateRange(1, 60)][int]$BootKeySeconds = 15,
        [ValidateRange(10, 1000)][int]$KeyIntervalMilliseconds = 250
    )

    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_5115fc3aa0fb34ef'))) { return }

    $ready = [Threading.ManualResetEventSlim]::new($false)
    $startFinished = [Threading.ManualResetEventSlim]::new($false)
    $keyboardArmed = [Threading.ManualResetEventSlim]::new($false)
    $cancel = [Threading.ManualResetEventSlim]::new($false)
    $workerState = [Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
    $workerState['Ready'] = $false
    $workerState['Error'] = ''
    $workerState['FinishedTick'] = [long]0
    $keyJob = $null
    try {
        $keyJob = Start-ThreadJob -ArgumentList $RepoRoot, $VMName, $ready, $startFinished, $keyboardArmed, $cancel,
            $workerState, $KeyDeliveryTimeoutSeconds, $BootKeySeconds, $KeyIntervalMilliseconds -ScriptBlock {
            param($Repository, $Name, $Ready, $StartFinished, $KeyboardArmed, $Cancel, $State, $DeliverySeconds, $BurstSeconds, $IntervalMilliseconds)
            $ErrorActionPreference = 'Stop'
            $transportLoaded = $false
            try {
                Import-Module (Join-Path $Repository 'host/macos.utm/modules/Yuruna.Host.psm1') -DisableNameChecking
                Import-Module (Join-Path $Repository 'test/modules/Test.Transport.psm1') -DisableNameChecking
                $transportLoaded = $true
                $State['Ready'] = $true
                $Ready.Set()

                $clock = [Diagnostics.Stopwatch]::StartNew()
                $firstKeyMilliseconds = $null
                $keysSent = 0
                $windowMilliseconds = [long]$BurstSeconds * 1000
                do {
                    if ($Cancel.IsSet) { return }
                    if ($null -ne $firstKeyMilliseconds) {
                        if ($clock.ElapsedMilliseconds - $firstKeyMilliseconds -ge $windowMilliseconds) { break }
                    } elseif ($clock.ElapsedMilliseconds -ge ([long]$DeliverySeconds * 1000) -or
                        ($StartFinished.IsSet -and [Environment]::TickCount64 - [long]$State['FinishedTick'] -ge $windowMilliseconds)) {
                        break
                    }

                    try {
                        # A bundle can initially name an occupied display.
                        # Startup reallocates it before arming this worker.
                        $display = if ($KeyboardArmed.IsSet) { Get-VncDisplayFromBundle -VMName $Name } else { -1 }
                        if ($display -ge 0 -and $KeyboardArmed.IsSet) {
                            $sent = Test.Transport\Send-KeyVNC -VMName $Name -KeyName Space -Port (5900 + $display)
                            if ($sent -is [bool] -and $sent) {
                                if ($null -eq $firstKeyMilliseconds) { $firstKeyMilliseconds = $clock.ElapsedMilliseconds }
                                $keysSent++
                            }
                        }
                    } catch {
                        Write-Verbose "Boot keyboard for '$Name' is not ready: $($_.Exception.Message)"
                    }
                    if ($Cancel.Wait($IntervalMilliseconds)) { return }
                } while ($true)

                [pscustomobject]@{ Success = ($keysSent -gt 0); KeysSent = $keysSent; ElapsedSeconds = [int][Math]::Ceiling($clock.Elapsed.TotalSeconds) }
            } catch {
                $State['Error'] = $_.Exception.Message
            } finally {
                # Also release the caller when loading the transport fails.
                $Ready.Set()
                if ($transportLoaded) { Test.Transport\Disconnect-VNC }
            }
        }

        if (-not $ready.Wait($ReadyTimeoutSeconds * 1000)) {
            throw [TimeoutException]::new((Format-YurunaOperatorMessage -Key 'host.windows_installer_boot_key_timeout' -Arguments @{
                vmName = $VMName; seconds = $ReadyTimeoutSeconds
            }))
        }
        if (-not $workerState['Ready']) {
            throw [InvalidOperationException]::new([string]$workerState['Error'])
        }

        $null = & $StartVM $keyboardArmed
        $workerState['FinishedTick'] = [Environment]::TickCount64
        $startFinished.Set()
        # Startup can still be waiting after the worker finished its burst.
        # Otherwise allow readiness, the burst, one bundle read (10 seconds),
        # and one VNC handshake (15 seconds).
        $null = Wait-Job -Job $keyJob -Timeout ($BootKeySeconds * 2 + 60)
        if ($keyJob.State -ne 'Completed' -or $workerState['Error']) {
            if ($workerState['Error']) { throw [InvalidOperationException]::new([string]$workerState['Error']) }
            throw [TimeoutException]::new((Format-YurunaOperatorMessage -Key 'host.windows_installer_boot_key_timeout' -Arguments @{
                vmName = $VMName; seconds = $KeyDeliveryTimeoutSeconds
            }))
        }
        $result = Receive-Job -Job $keyJob -ErrorAction Stop
        if ($null -eq $result -or -not $result.Success) {
            throw [TimeoutException]::new((Format-YurunaOperatorMessage -Key 'host.windows_installer_boot_key_timeout' -Arguments @{
                vmName = $VMName; seconds = $(if ($result) { $result.ElapsedSeconds } else { $KeyDeliveryTimeoutSeconds })
            }))
        }
    } finally {
        $cancel.Set()
        if ($keyJob) {
            if ($keyJob.State -in @('Running', 'NotStarted')) { Stop-Job -Job $keyJob -ErrorAction SilentlyContinue }
            Remove-Job -Job $keyJob -Force -ErrorAction SilentlyContinue
        }
        $ready.Dispose()
        $startFinished.Dispose()
        $keyboardArmed.Dispose()
        $cancel.Dispose()
    }
}

Export-ModuleMember -Function Start-YurunaWindowsInstallerVnc
