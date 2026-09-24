<#PSScriptInfo
.VERSION 2026.09.24
.GUID 4289a687-9c25-47df-950d-d43149e821f8
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

# Default notification extension. See
# ../../../docs/extensions-api.md#areas-today for what it dispatches and where
# its runtime config lives. -- default.psm1

# Module file lives at test/extension/notification/default.psm1; three
# Split-Path -Parent calls reach the repo root.
$script:ExtensionDir = $PSScriptRoot
$script:RepoRoot     = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:ExtensionDir))
$script:StateDir     = Join-Path -Path $script:RepoRoot -ChildPath 'test' `
                          -AdditionalChildPath 'status', 'extension', 'notification'
$script:ConfigPath   = Join-Path $script:StateDir 'transports.yml'

Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

function Read-NotificationConfig {
    if (-not (Test-Path $script:ConfigPath)) {
        Write-Verbose "transports.yml not found at $script:ConfigPath; treating as empty."
        return [ordered]@{ transports = [ordered]@{}; subscribers = [ordered]@{} }
    }
    $parsed = $null
    try {
        $parsed = Get-Content -Raw $script:ConfigPath | ConvertFrom-Yaml -Ordered
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'notification.config_parse_failed' -Arguments @{ detail = $_.Exception.Message })
        return [ordered]@{ transports = [ordered]@{}; subscribers = [ordered]@{} }
    }
    # Normalize the success path to one stable shape so every consumer sees an
    # IDictionary carrying both transports and subscribers. A valid-but-odd
    # transports.yml -- empty or comment-only (ConvertFrom-Yaml returns $null),
    # a top-level scalar or list, or a mapping missing either key -- would
    # otherwise reach Send-Notification's $cfg.Contains('subscribers') and
    # throw, since a null / non-dictionary has no key-membership contract.
    if ($parsed -isnot [System.Collections.IDictionary]) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'notification.config_mapping_required')
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
        throw (Format-YurunaOperatorMessage -Key 'notification.resend_config_required')
    }
    $headers = @{
        'Authorization' = "Bearer $($ResendCfg.apiKey)"
        'Content-Type'  = 'application/json'
    }
    # Both parts, always. With html alone the provider synthesizes whatever
    # plain-text part it likes for clients that ask for one, and the reader gets
    # a machine's guess at a message we already hold in its original form. The
    # html part wraps rather than scrolling: an unwrapped <pre> turns one long
    # command line into a horizontal scroll in every client that honors it.
    # It also states both of its own colors. A fragment that sets neither
    # inherits whatever the client paints behind it, and a dark-mode client
    # renders the default near-black text onto a near-black ground.
    $locale = Get-YurunaOperatorLocale
    $body = @{
        from    = $ResendCfg.fromEmail
        to      = $ToAddress
        subject = $Subject
        text    = $BodyText
        html    = "<html lang=`"$($locale.ResolvedTag)`" dir=`"$($locale.Direction)`"><body style=`"background:#ffffff;color:#111827`"><pre style=`"white-space:pre-wrap;word-wrap:break-word;color:#111827`">$([System.Net.WebUtility]::HtmlEncode($BodyText))</pre></body></html>"
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
                    Write-Information (Format-YurunaOperatorMessage -Key 'notification.delivered' -Arguments @{ eventCode = $EventCode; address = $sub.address }) -InformationAction Continue
                }
                default {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'notification.unknown_transport' -Arguments @{ eventCode = $EventCode; transport = $sub.transport })
                }
            }
        } catch {
            $lastError = $_.Exception.Message
            Write-Warning (Format-YurunaOperatorMessage -Key 'notification.delivery_failed' -Arguments @{ eventCode = $EventCode; address = $sub.address; detail = $lastError })
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
        throw (Format-YurunaOperatorMessage -Key 'notification.all_delivery_failed' -Arguments @{ eventCode = $EventCode; attempted = $attempted; detail = $lastError })
    }
}

Export-ModuleMember -Function Send-Notification
