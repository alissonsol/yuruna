<#PSScriptInfo
.VERSION 0.1
.GUID a1b2c3d4-e5f6-4789-8abc-def012345603
.AUTHOR Alisson Sol
.COMPANYNAME None
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

# Dispatches a notification via SMTP or webhook based on config.notification.type.
function Send-Notification {
    param(
        $Config,
        [string]$Subject,
        [string]$Body
    )
    $notif = $Config.notification
    if (-not $notif) { Write-Warning "No notification config found."; return }
    if (-not $notif.toAddress -and -not $notif.webhook.url) {
        Write-Warning "No notification address configured. Set notification.toAddress or notification.webhook.url in test-config.json."
        return
    }
    switch ($notif.type) {
        "smtp"    { Send-SmtpNotification    -Notif $notif -Subject $Subject -Body $Body }
        "slack"   { Send-WebhookNotification -Notif $notif -Subject $Subject -Body $Body -Format "slack" }
        "teams"   { Send-WebhookNotification -Notif $notif -Subject $Subject -Body $Body -Format "teams" }
        "webhook" { Send-WebhookNotification -Notif $notif -Subject $Subject -Body $Body -Format "slack" }
        default   { Write-Warning "Unknown notification type: $($notif.type). Set type to smtp, webhook, slack, or teams." }
    }
}

function Send-SmtpNotification {
    param($Notif, [string]$Subject, [string]$Body)
    try {
        $smtp   = $Notif.smtp
        $client = [System.Net.Mail.SmtpClient]::new($smtp.server, [int]$smtp.port)
        $client.EnableSsl = [bool]$smtp.useTls
        if ($smtp.username) {
            $client.Credentials = [System.Net.NetworkCredential]::new($smtp.username, $smtp.password)
        }
        $msg = [System.Net.Mail.MailMessage]::new($smtp.fromAddress, $Notif.toAddress, $Subject, $Body)
        $client.Send($msg)
        $msg.Dispose()
        Write-Output "Notification sent via SMTP to: $($Notif.toAddress)"
    } catch {
        Write-Warning "Failed to send SMTP notification: $_"
    }
}

function Send-WebhookNotification {
    param($Notif, [string]$Subject, [string]$Body, [string]$Format = "slack")
    try {
        $url = $Notif.webhook.url
        if (-not $url) { Write-Warning "No webhook URL configured in notification.webhook.url."; return }
        $text = "$Subject`n`n$Body"
        $payload = if ($Format -eq "teams") {
            @{ "@type" = "MessageCard"; "@context" = "http://schema.org/extensions"; summary = $Subject; text = $text }
        } else {
            @{ text = $text }
        }
        Invoke-RestMethod -Uri $url -Method Post -Body ($payload | ConvertTo-Json -Compress) -ContentType "application/json" | Out-Null
        Write-Output "Notification sent via webhook ($Format)."
    } catch {
        Write-Warning "Failed to send webhook notification: $_"
    }
}

# Builds a human-readable failure message for notifications.
function Format-FailureMessage {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$StepName,
        [string]$ErrorMessage,
        [string]$RunId,
        [string]$GitCommit
    )
    return @"
Yuruna VDE Test Failure

Host:    $HostType
Guest:   $GuestKey
Step:    $StepName
Error:   $ErrorMessage
Run ID:  $RunId
Commit:  $GitCommit
Time:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')
"@
}

Export-ModuleMember -Function Send-Notification, Format-FailureMessage
