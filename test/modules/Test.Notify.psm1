<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456703
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    Dispatches a notification via the Resend API based on config.notification.
#>
function Send-Notification {
    param(
        $Config,
        [string]$Subject,
        [string]$Body
    )
    $notif = $Config.notification
    if (-not $notif) { Write-Warning "No notification config found."; return }
    if (-not $notif.toAddress) {
        Write-Warning "No notification address configured. Set notification.toAddress in test-config.json (copy from test-config.json.template)."
        return
    }

    $resend = $notif.resend
    if (-not $resend -or -not $resend.apiKey -or -not $resend.from) {
        throw "Resend configuration incomplete: notification.resend.apiKey and notification.resend.from are required."
    }

    $headers = @{
        "Authorization" = "Bearer $($resend.apiKey)"
        "Content-Type"  = "application/json"
    }

    $emailBody = @{
        from    = $resend.from
        to      = $notif.toAddress
        subject = $Subject
        html    = "<pre>$([System.Net.WebUtility]::HtmlEncode($Body))</pre>"
    } | ConvertTo-Json

    Invoke-RestMethod -Uri "https://api.resend.com/emails" -Method Post -Headers $headers -Body $emailBody | Out-Null
    Write-Information "Notification sent via Resend API to: $($notif.toAddress)" -InformationAction Continue
}

<#
.SYNOPSIS
    Builds a human-readable failure message for notifications.
#>
function Format-FailureMessage {
    param(
        [string]$HostType,
        [string]$Hostname,
        [string]$GuestKey,
        [string]$StepName,
        [string]$ErrorMessage,
        [string]$RunId,
        [string]$GitCommit
    )
    return @"
Yuruna VDE Test Failure

Host:     $HostType
Machine:  $Hostname
Guest:    $GuestKey
Step:     $StepName
Error:    $ErrorMessage
Run ID:   $RunId
Commit:   $GitCommit
Time:     $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC
"@
}

Export-ModuleMember -Function Send-Notification, Format-FailureMessage
