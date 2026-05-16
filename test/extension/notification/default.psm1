<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456812
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

# Default notification extension: dispatches each event to the
# email-transport subscribers listed in notification.transports.yml,
# delivered via Resend's REST API. Empty/missing subscriber lists are a
# silent no-op (Verbose only) so first-run users do not get errors
# before they fill in the config.

$script:NotificationDir = $PSScriptRoot
$script:ConfigPath      = Join-Path $script:NotificationDir 'notification.transports.yml'

function Read-NotificationConfig {
    if (-not (Test-Path $script:ConfigPath)) {
        Write-Verbose "notification.transports.yml not found at $script:ConfigPath; treating as empty."
        return [ordered]@{ transports = [ordered]@{}; subscribers = [ordered]@{} }
    }
    try {
        return (Get-Content -Raw $script:ConfigPath | ConvertFrom-Yaml -Ordered)
    } catch {
        Write-Warning "notification.transports.yml parse failed: $($_.Exception.Message). Treating as empty."
        return [ordered]@{ transports = [ordered]@{}; subscribers = [ordered]@{} }
    }
}

function Send-EmailViaResend {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ResendCfg,
        [Parameter(Mandatory)][string]$ToAddress,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$BodyText
    )
    if (-not $ResendCfg -or -not $ResendCfg.apiKey -or -not $ResendCfg.fromEmail) {
        throw "transports.resend.apiKey and transports.resend.fromEmail are required."
    }
    $headers = @{
        'Authorization' = "Bearer $($ResendCfg.apiKey)"
        'Content-Type'  = 'application/json'
    }
    $body = @{
        from    = $ResendCfg.fromEmail
        to      = $ToAddress
        subject = $Subject
        html    = "<pre>$([System.Net.WebUtility]::HtmlEncode($BodyText))</pre>"
    } | ConvertTo-Json
    Invoke-RestMethod -Uri 'https://api.resend.com/emails' -Method Post -Headers $headers -Body $body -Verbose:$false -Debug:$false | Out-Null
}

<#
.SYNOPSIS
    Sends a notification for $EventCode to every subscriber configured for it.
#>
function Send-Notification {
    param(
        [Parameter(Mandatory)][string]$EventCode,
        [Parameter(Mandatory)][string]$EventMessage,
        [string]$EventNote = ''
    )
    $cfg = Read-NotificationConfig
    $subs = @()
    if ($cfg.Contains('subscribers') -and $cfg.subscribers -and $cfg.subscribers.Contains($EventCode)) {
        $subs = @($cfg.subscribers[$EventCode])
    }
    if ($subs.Count -eq 0) {
        Write-Verbose "No subscribers for event '$EventCode'; nothing to send."
        return
    }
    foreach ($sub in $subs) {
        try {
            switch ($sub.transport) {
                'email' {
                    if (-not $sub.address) {
                        Write-Verbose "Subscriber for '$EventCode' has empty address; skipping."
                        continue
                    }
                    Send-EmailViaResend -ResendCfg $cfg.transports.resend `
                        -ToAddress $sub.address -Subject $EventMessage -BodyText $EventNote
                    Write-Information "Notification '$EventCode' delivered to $($sub.address)" -InformationAction Continue
                }
                default {
                    Write-Warning "Unknown transport '$($sub.transport)' for event '$EventCode'."
                }
            }
        } catch {
            Write-Warning "Notification delivery failed for '$EventCode' -> $($sub.address): $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function Send-Notification
