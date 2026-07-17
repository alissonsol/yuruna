<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456812
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Default notification extension: dispatches each event to the
# email-transport subscribers listed in transports.yml, delivered via
# Resend's REST API. Empty/missing subscriber lists are a silent no-op
# (Verbose only) so first-run users do not get errors before they fill
# in the config.
#
# Runtime config (transports.yml -- carries the Resend API key) lives
# under test/status/extension/notification/ so it sits with the rest of
# the harness state that is wiped when cleaning a host. The committed
# extension code (and the .template seed) live under
# test/extension/notification/.

# Module file lives at test/extension/notification/default.psm1; three
# Split-Path -Parent calls reach the repo root.
$script:ExtensionDir = $PSScriptRoot
$script:RepoRoot     = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:ExtensionDir))
$script:StateDir     = Join-Path -Path $script:RepoRoot -ChildPath 'test' `
                          -AdditionalChildPath 'status', 'extension', 'notification'
$script:ConfigPath   = Join-Path $script:StateDir 'transports.yml'

function Read-NotificationConfig {
    if (-not (Test-Path $script:ConfigPath)) {
        Write-Verbose "transports.yml not found at $script:ConfigPath; treating as empty."
        return [ordered]@{ transports = [ordered]@{}; subscribers = [ordered]@{} }
    }
    $parsed = $null
    try {
        $parsed = Get-Content -Raw $script:ConfigPath | ConvertFrom-Yaml -Ordered
    } catch {
        Write-Warning "transports.yml parse failed: $($_.Exception.Message). Treating as empty."
        return [ordered]@{ transports = [ordered]@{}; subscribers = [ordered]@{} }
    }
    # Normalize the success path to one stable shape so every consumer sees an
    # IDictionary that has both transports and subscribers. A valid-but-oddly-shaped
    # transports.yml -- an empty / comment-only file (ConvertFrom-Yaml returns
    # $null), a top-level scalar or list, or a mapping missing either key -- would
    # otherwise reach Send-Notification's $cfg.Contains('subscribers') and throw,
    # since a null / non-dictionary has no key-membership contract.
    if ($parsed -isnot [System.Collections.IDictionary]) {
        Write-Warning "transports.yml did not parse to a mapping; treating as empty."
        return [ordered]@{ transports = [ordered]@{}; subscribers = [ordered]@{} }
    }
    if (-not $parsed.Contains('transports') -or $parsed['transports'] -isnot [System.Collections.IDictionary]) {
        $parsed['transports'] = [ordered]@{}
    }
    if (-not $parsed.Contains('subscribers') -or $parsed['subscribers'] -isnot [System.Collections.IDictionary]) {
        $parsed['subscribers'] = [ordered]@{}
    }
    return $parsed
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
    # -TimeoutSec bounds the call so a stalled Resend endpoint can't wedge a caller
    # (the file-spool pool notifier runs as an unattended cycle-end hook; an unbounded
    # POST there is the "outer-loop hook must be subprocess-bounded" trap class).
    Invoke-RestMethod -Uri 'https://api.resend.com/emails' -Method Post -Headers $headers -Body $body -TimeoutSec 30 -Verbose:$false -Debug:$false | Out-Null
}

<#
.SYNOPSIS
    Sends a notification for $EventCode to every subscriber configured for it.
#>
function Send-Notification {
    param(
        [Parameter(Mandatory)][string]$EventCode,
        [Parameter(Mandatory)][string]$EventMessage,
        [string]$EventNote = '',
        # Optional structured failure payload (schema-v2 shape). The Test.Notify
        # forward gate ships it only to extensions that DECLARE this parameter;
        # the Resend email transport delivers the human EventNote (which already
        # carries the JSON trailer from Format-FailureMessage), so this is
        # accepted for the gate + a future webhook/richer transport that routes
        # on $EventData.failureClass without regex-parsing the body.
        [hashtable]$EventData = $null
    )
    # Accepted-but-unused by the email path today; reference it so the param
    # surface is intentional (and PSReviewUnusedParameter stays quiet).
    Write-Verbose "Send-Notification: EventData $(if ($EventData) { "present (failureClass=$($EventData['failureClass']))" } else { 'none' })"
    $cfg = Read-NotificationConfig
    $subs = @()
    if ($cfg.Contains('subscribers') -and $cfg.subscribers -and $cfg.subscribers.Contains($EventCode)) {
        $subs = @($cfg.subscribers[$EventCode])
    }
    if ($subs.Count -eq 0) {
        Write-Verbose "No subscribers for event '$EventCode'; nothing to send."
        return
    }
    $attempted = 0
    $delivered = 0
    $lastError = $null
    foreach ($sub in $subs) {
        try {
            switch ($sub.transport) {
                'email' {
                    if (-not $sub.address) {
                        Write-Verbose "Subscriber for '$EventCode' has empty address; skipping."
                        continue
                    }
                    $attempted++
                    Send-EmailViaResend -ResendCfg $cfg.transports.resend `
                        -ToAddress $sub.address -Subject $EventMessage -BodyText $EventNote
                    $delivered++
                    Write-Information "Notification '$EventCode' delivered to $($sub.address)" -InformationAction Continue
                }
                default {
                    Write-Warning "Unknown transport '$($sub.transport)' for event '$EventCode'."
                }
            }
        } catch {
            $lastError = $_.Exception.Message
            Write-Warning "Notification delivery failed for '$EventCode' -> $($sub.address): $lastError"
        }
    }
    # Surface a TOTAL delivery failure to the dispatcher so its delivery ledger
    # (notification.delivery.json) records 'fail' rather than a false 'ok'. The
    # dispatcher's sync + async branches both catch this, so it never crashes a
    # caller -- it just makes the recorded outcome honest, which the file-spool pool
    # notifier keys on to retry (vs dropping) an undelivered message. A partial
    # success (>=1 delivered) still counts as delivered; skipped subscribers (no
    # address / unknown transport) are not delivery attempts.
    if ($attempted -gt 0 -and $delivered -eq 0) {
        throw "Notification '$EventCode': all $attempted delivery attempt(s) failed. Last error: $lastError"
    }
}

Export-ModuleMember -Function Send-Notification
