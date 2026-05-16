<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456703
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Send-Notification is now a thin dispatcher to the active extensions
# under test/extension/notification/. The contract is:
#   Send-Notification -EventCode <string> -EventMessage <string> -EventNote <string>
# Format-FailureMessage stays here so callers can build the EventNote
# body from structured fields without re-implementing the format.

# Import the extension loader once. Test.Extension imports the active
# notification module(s) into the global scope so their Send-Notification
# becomes the resolved binding.
$script:ExtensionLoader = Join-Path $PSScriptRoot 'Test.Extension.psm1'
if (Test-Path $script:ExtensionLoader) {
    Import-Module $script:ExtensionLoader -Global -Force
}

$script:NotificationExtensionsLoaded = $false

function Initialize-NotificationExtension {
    if ($script:NotificationExtensionsLoaded) { return }
    try {
        [void](Import-Extension -Area 'notification')
        $script:NotificationExtensionsLoaded = $true
    } catch {
        Write-Warning "Notification extension load failed: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Dispatches a notification event to every active notification extension.
.DESCRIPTION
    Each extension's Send-Notification is invoked in turn. Per the spec,
    notification iterates the active list (multi-transport future). Today
    the default extension handles email-via-Resend; additional transports
    are added by dropping a new <name>.psm1 next to default.psm1 and
    listing it in notification.config.yml.
#>
function Send-Notification {
    param(
        [Parameter(Mandatory)][string]$EventCode,
        [Parameter(Mandatory)][string]$EventMessage,
        [string]$EventNote = ''
    )
    Initialize-NotificationExtension
    $names = @()
    try { $names = @(Get-ActiveExtensionName -Area 'notification') } catch { Write-Warning $_.Exception.Message; return }
    # Path-based lookup: two areas can ship a module with the same
    # basename (notification/default.psm1, authentication/default.psm1)
    # and both register under PowerShell module name 'default'. A name-
    # filtered Get-Command then misses Send-Notification when the auth
    # extension was loaded after the notification one. Matching by the
    # loaded .psm1's absolute path bypasses the collision.
    $areaDir = Resolve-ExtensionAreaDir -Area 'notification'
    foreach ($n in $names) {
        $modPath = [System.IO.Path]::GetFullPath((Join-Path $areaDir "$n.psm1"))
        $mod = Get-Module | Where-Object {
            $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -eq $modPath)
        } | Select-Object -First 1
        if (-not $mod) {
            try {
                Import-Module -Name $modPath -Global -Force -Verbose:$false -ErrorAction Stop
                $mod = Get-Module | Where-Object {
                    $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -eq $modPath)
                } | Select-Object -First 1
            } catch {
                Write-Warning "Notification extension '$n' re-import threw: $($_.Exception.Message)"
            }
        }
        $cmd = $null
        if ($mod -and $mod.ExportedCommands.ContainsKey('Send-Notification')) {
            $cmd = $mod.ExportedCommands['Send-Notification']
        }
        if (-not $cmd) {
            $loaded = @(Get-Module | Where-Object { $_.Name -eq $n } | ForEach-Object { $_.Path })
            $loadedMsg = if ($loaded.Count -gt 0) { "module loaded from: $($loaded -join ', ')" } else { 'no module named "' + $n + '" is currently loaded' }
            Write-Warning "Notification extension '$n' does not export Send-Notification (looked for $modPath; $loadedMsg)."
            continue
        }
        try {
            & $cmd -EventCode $EventCode -EventMessage $EventMessage -EventNote $EventNote
        } catch {
            Write-Warning "Notification extension '$n' threw: $($_.Exception.Message)"
        }
    }
}

<#
.SYNOPSIS
    Builds a human-readable failure message body for notifications.
#>
function Format-FailureMessage {
    param(
        [string]$HostType,
        [string]$Hostname,
        [string]$GuestKey,
        [string]$StepName,
        [string]$ErrorMessage,
        [string]$CycleId,
        [string]$GitCommit
    )
    return @"
Yuruna Test Failure

Host:     $HostType
Machine:  $Hostname
Guest:    $GuestKey
Step:     $StepName
Error:    $ErrorMessage
Cycle ID: $CycleId
Commit:   $GitCommit
Time:     $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC
"@
}

Export-ModuleMember -Function Send-Notification, Format-FailureMessage
