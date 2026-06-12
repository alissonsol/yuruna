<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456703
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

# $global:__YurunaCycleFolder is intentionally process-wide -- shared with
# Test.Log.psm1 (which sets it in Start-LogFile) and consumed here as a
# fallback when no -CycleFolder argument is passed. See Test.Log.psm1's
# matching SuppressMessageAttribute for the canonical rationale.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'global:__YurunaCycleFolder is the cross-module cycle folder handle set by Test.Log.psm1''s Start-LogFile and read here as a fallback when no -CycleFolder is supplied; intentionally process-wide.')]
param()

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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventCode,
        [Parameter(Mandatory)][string]$EventMessage,
        [string]$EventNote = '',
        # Optional structured payload forwarded to each extension's
        # Send-Notification (the extension decides whether to ship it as
        # a JSON body field, an HTTP header, or ignore it). Webhook
        # consumers can route on $EventData.failureClass etc. without
        # regex-parsing the free-text body.
        [hashtable]$EventData = $null,
        # Dispatch each extension's Send-Notification asynchronously via
        # Start-ThreadJob so the failure path is not blocked on a 1-5 s
        # Resend HTTP roundtrip. Delivery becomes best-effort; CI
        # callers that need synchronous delivery pass -Synchronous.
        [switch]$Synchronous
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
        # Forward -EventData only when the extension's Send-Notification
        # declares the parameter -- older extensions that predate the
        # parameter still receive the three legacy fields and silently
        # ignore the structured payload.
        $cmdParams = @{ EventCode = $EventCode; EventMessage = $EventMessage; EventNote = $EventNote }
        if ($EventData -and $cmd.Parameters.ContainsKey('EventData')) {
            $cmdParams['EventData'] = $EventData
        }
        if ($Synchronous -or -not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
            $delivered = $false
            $deliveryErr = $null
            try {
                & $cmd @cmdParams
                $delivered = $true
            } catch {
                $deliveryErr = $_.Exception.Message
                Write-Warning "Notification extension '$n' threw: $deliveryErr"
            }
            $statusValue = if ($delivered) { 'ok' } else { 'fail' }
            Write-NotificationDelivery -ExtensionName $n -EventCode $EventCode -Status $statusValue -ErrorMessage $deliveryErr -ModeIsAsync $false
        } else {
            # Fire-and-forget; the cycle's failure path returns immediately.
            # The thread job inherits the runspace's module table so $cmd
            # resolves the same way as the synchronous branch.
            #
            # Delivery outcome is persisted to <cycleFolder>/notification.delivery.json
            # (append-only JSON Lines) from inside the thread job so an
            # autonomous remediator can see whether the escalation channel
            # actually received the alert. Without this, a Resend HTTP 503
            # is swallowed at Write-Warning and the cycle's transcript looks
            # like the operator was notified when no one was.
            $deliveryFunc = ${function:Write-NotificationDelivery}
            $cycleFolder  = $global:__YurunaCycleFolder
            $null = Start-ThreadJob -Name "Send-Notification-$n" -ScriptBlock {
                # Mirror $using: captures to locals at the top of the
                # scriptblock so the rest of the body (including string
                # interpolation) stays readable.
                $cmd          = $using:cmd
                $p            = $using:cmdParams
                $n            = $using:n
                $eventCode    = $using:EventCode
                $cycleFolder  = $using:cycleFolder
                $deliveryFunc = $using:deliveryFunc
                $delivered = $false
                $deliveryErr = $null
                try {
                    & $cmd @p
                    $delivered = $true
                } catch {
                    $deliveryErr = $_.Exception.Message
                    Write-Warning "Notification extension '$n' threw: $deliveryErr"
                }
                # Re-materialize the delivery-writer in this runspace and
                # invoke it. The thread job has its own module table; the
                # function reference passed in survives the boundary.
                if ($deliveryFunc) {
                    try {
                        $writer = [scriptblock]::Create($deliveryFunc.ToString())
                        $statusValue = if ($delivered) { 'ok' } else { 'fail' }
                        & $writer -ExtensionName $n -EventCode $eventCode `
                            -Status $statusValue `
                            -ErrorMessage $deliveryErr -ModeIsAsync $true -CycleFolder $cycleFolder
                    } catch { Write-Verbose "notification.delivery.json write (async) failed: $($_.Exception.Message)" }
                }
            }
        }
    }
}

function Write-NotificationDelivery {
    <#
    .SYNOPSIS
        Append a delivery-outcome record to <cycleFolder>/notification.delivery.json
        (JSON Lines).
    .DESCRIPTION
        One record per extension per Send-Notification call:
            { timestamp; eventCode; extension; status; mode; errorMessage }
        Best-effort -- a failed write logs Verbose and returns rather
        than throwing back into Send-Notification's dispatch loop.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Append-only telemetry; failures are silent (Write-Verbose only).')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the cycle-folder anchor set by Test.Log.psm1''s Start-LogFile.')]
    param(
        [Parameter(Mandatory)][string]$ExtensionName,
        [Parameter(Mandatory)][string]$EventCode,
        [Parameter(Mandatory)][ValidateSet('ok','fail')][string]$Status,
        # ErrorMessage (not $Error) to avoid shadowing the automatic
        # $Error variable inside this function's body.
        [string]$ErrorMessage,
        [bool]$ModeIsAsync = $false,
        [string]$CycleFolder
    )
    if (-not $CycleFolder) { $CycleFolder = [string]$global:__YurunaCycleFolder }
    if (-not $CycleFolder) { return }
    $record = [ordered]@{
        timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        eventCode    = $EventCode
        extension    = $ExtensionName
        status       = $Status
        mode         = if ($ModeIsAsync) { 'async' } else { 'sync' }
        errorMessage = $ErrorMessage
    } | ConvertTo-Json -Compress -Depth 3
    $path = Join-Path $CycleFolder 'notification.delivery.json'
    try {
        Add-Content -LiteralPath $path -Value $record -Encoding utf8NoBOM -ErrorAction Stop
    } catch {
        Write-Verbose "Write-NotificationDelivery: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Builds a human-readable failure message body for notifications.
.DESCRIPTION
    Returns a text block ready for plain-text email transport. When
    -EventData is supplied (typically the same hashtable shipped via
    Send-Notification -EventData), a machine-readable trailer is
    appended after a `--- yuruna-failure-json ---` marker line so an
    LLM/webhook consumer that only sees the body can still recover
    failureClass / severity / cycleFolderUrl / suggestedRecoveries
    without regex-parsing the human text. Legacy callers that pass
    only the scalar fields get the original body untouched.
#>
function Format-FailureMessage {
    param(
        [string]$HostType,
        [string]$Hostname,
        [string]$GuestKey,
        [string]$StepName,
        [string]$ErrorMessage,
        [string]$CycleId,
        [string]$GitCommit,
        [hashtable]$EventData = $null
    )
    $body = @"
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
    if (-not $EventData) { return $body }

    # Quick-scan trailer: surfaces the v2 fields a remediator routes on
    # AND keeps the full JSON below so structured consumers don't lose
    # anything. -- marker delimiters are stable so a future parser can
    # split body / json without regex on the human text.
    $get = {
        param($Key)
        if ($EventData.Contains($Key)) { [string]$EventData[$Key] } else { '' }
    }
    $suggested = ''
    if ($EventData.Contains('suggestedRecoveries')) {
        $suggested = @($EventData['suggestedRecoveries']) -join ', '
    }
    # Repro command: in last_failure.json it is the nested repro.command; a flat
    # event-shaped payload carries it as reproCommand. Surface it prominently so
    # an operator (or LLM remediator) reading the body has a copy-paste rerun
    # without digging through the JSON dump below.
    $reproCmd = ''
    if ($EventData.Contains('repro') -and ($EventData['repro'] -is [System.Collections.IDictionary]) -and $EventData['repro'].Contains('command')) {
        $reproCmd = [string]$EventData['repro']['command']
    } elseif ($EventData.Contains('reproCommand')) {
        $reproCmd = [string]$EventData['reproCommand']
    }
    $jsonDump = ''
    try {
        $jsonDump = $EventData | ConvertTo-Json -Depth 6
    } catch {
        $jsonDump = '(could not serialize EventData: ' + $_.Exception.Message + ')'
    }
    $trailer = @"

--- yuruna-failure-summary ---
failureClass:         $(& $get 'failureClass')
classificationSource: $(& $get 'classificationSource')
severity:             $(& $get 'severity')
actionVerb:           $(& $get 'actionVerb')
cycleFolderUrl:       $(& $get 'cycleFolderUrl')
suggestedRecoveries:  $suggested
repro:                $reproCmd

--- yuruna-failure-json ---
$jsonDump
--- end yuruna-failure-json ---
"@
    return $body + $trailer
}

<#
.SYNOPSIS
    Builds the structured -EventData payload for Send-Notification.
.DESCRIPTION
    Returns a hashtable shaped like Invoke-Sequence's failure-schema v2,
    augmented with cycle/host context the failure file does not itself
    record. Pass to Send-Notification -EventData; webhook/email
    extensions that declare the -EventData parameter receive the payload
    and can route on $EventData.failureClass without regex-parsing the
    free-text body.

    Loads the cycle's last_failure.json when available (cycleFolder
    parameter, or $global:__YurunaCycleFolder fallback). Bootstrap-stage
    callers (GitPull / ProjectClone failures fire before Start-LogFile
    runs) get a minimal payload built from the scalar arguments alone.

    All identity fields are optional so a partial payload still ships
    rather than a missing one.
#>
function Get-FailureEventData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$CycleFolder,
        [string]$HostType,
        [string]$Hostname,
        [string]$GuestKey,
        [string]$StepName,
        [string]$ErrorMessage,
        [string]$CycleId,
        [string]$GitCommit,
        [string]$ProjectCommit,
        # Used when no last_failure.json exists (bootstrap stages
        # before Start-LogFile). Defaults to 'unknown'.
        [string]$DefaultFailureClass = 'unknown',
        [string]$DefaultSeverity     = 'unknown'
    )
    if (-not $CycleFolder -and $global:__YurunaCycleFolder) {
        $CycleFolder = [string]$global:__YurunaCycleFolder
    }

    $payload = $null
    if ($CycleFolder) {
        $failureFile = Join-Path $CycleFolder 'last_failure.json'
        if (Test-Path -LiteralPath $failureFile) {
            try {
                $raw = Get-Content -LiteralPath $failureFile -Raw -ErrorAction Stop
                if ($raw) {
                    $parsed = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    if ($parsed -is [hashtable]) { $payload = $parsed }
                }
            } catch {
                Write-Verbose "Get-FailureEventData: could not parse $failureFile -- $($_.Exception.Message)"
            }
        }
    }

    if (-not $payload) {
        $payload = @{
            schemaVersion       = 2
            failureClass        = $DefaultFailureClass
            severity            = $DefaultSeverity
            actionVerb          = $StepName
            action              = $StepName
            description         = $ErrorMessage
            suggestedRecoveries = @()
            timestamp           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    # Cycle-level context the failure file does not record. Set even
    # when fields are empty so consumers see a consistent shape.
    $payload['cycleId']       = $CycleId
    $payload['hostType']      = if ($HostType) { $HostType } else { $payload['hostType'] }
    $payload['hostname']      = $Hostname
    $payload['guestKey']      = if ($GuestKey) { $GuestKey } else { $payload['guestKey'] }
    $payload['stepName']      = if ($StepName) { $StepName } else { $payload['actionVerb'] }
    $payload['errorMessage']  = if ($ErrorMessage) { $ErrorMessage } else { $payload['action'] }
    $payload['gitCommit']     = $GitCommit
    $payload['projectCommit'] = $ProjectCommit

    # Cycle folder URL: the cycle log's basename appended to the status
    # server's mount. Consumers can deep-link from the notification
    # straight to the HTML transcript + artifacts.
    #
    # Base URL precedence:
    #   1. $env:YURUNA_STATUS_PUBLIC_URL -- explicitly published reachable
    #      address (operator sets this on hosts whose dashboard is
    #      exposed via a reverse proxy, a tunnelled hostname, or a LAN
    #      IP). An off-host LLM remediator can follow the link.
    #   2. http://<HOST_FQDN>:<statusService.port> -- best guess from the
    #      cycle's recorded hostname + the running status server port,
    #      when both are known. Works on most LANs where the dashboard
    #      hostname resolves.
    #   3. http://localhost:8080/ -- last-resort fallback. Only useful
    #      to a consumer running on the same host as the runner.
    $cycleFolderBaseUrl = $null
    if ($env:YURUNA_STATUS_PUBLIC_URL) {
        $cycleFolderBaseUrl = $env:YURUNA_STATUS_PUBLIC_URL.TrimEnd('/')
    } elseif ($Hostname) {
        # statusService.port defaults to 8080; the actual value isn't
        # plumbed through this function but the default covers the
        # vast majority of deployments. Operators that customize the
        # port should also set YURUNA_STATUS_PUBLIC_URL.
        $cycleFolderBaseUrl = "http://${Hostname}:8080"
    } else {
        $cycleFolderBaseUrl = "http://localhost:8080"
    }
    if ($CycleFolder) {
        # Emit the cycle's stable identity in notifications so a
        # URL the operator clicks resolves to the post-rename location
        # at <base>/, not the transient <base>.incomplete/ that may
        # already be gone by the time the email reaches them.
        $cycleBase = if (Get-Command Get-CycleFolderIdentity -ErrorAction SilentlyContinue) {
            Get-CycleFolderIdentity -Path $CycleFolder
        } else {
            Split-Path -Leaf $CycleFolder
        }
        $payload['cycleFolder']    = $CycleFolder
        $payload['cycleFolderUrl'] = "$cycleFolderBaseUrl/status/log/$cycleBase/"
    }

    return $payload
}

<#
.SYNOPSIS
    Builds the failure-notification body and dispatches it for a cycle failure.
.DESCRIPTION
    Collapses the duplicated "format the body, then Send-Notification" unit
    shared by the cycle-failure sites in Invoke-TestInnerRunner.ps1 into one
    place. Owns ONLY that build-body-and-send step: the fixed EventCode
    'cycle.failure', the fixed subject prefix "Yuruna Test: FAIL on <HostType>
    / " with the caller-supplied -SubjectSuffix appended, Format-FailureMessage
    (the human body plus its JSON trailer), and Send-Notification.

    It deliberately does NOT gate (AlertArmed / ConsecutiveFailures), does NOT
    remediate, and does NOT disarm, exit, or write status output. Those
    side-effects differ per site (a bootstrap site exits; an in-cycle site
    disarms and reports a suppressed-until line) and stay inline at the call
    site. In particular the in-cycle / post-loop sites run Invoke-Remediation
    on the payload BEFORE the send -- an ordering the caller keeps visible by
    remediating inline and handing the already-built payload here.

    Payload sourcing:
      * In-cycle / post-loop callers pre-build the payload (so they can run
        Invoke-Remediation against it first) and pass it via -EventData; the
        helper reuses that exact hashtable and skips its own build, so the
        shipped payload is byte-identical to the remediated one.
      * Bootstrap callers fire before the cycle folder exists, so no
        last_failure.json is present and nothing downstream consumes the
        payload after the send. They let the helper build it by passing
        -DefaultFailureClass / -DefaultSeverity and omitting -EventData.

    Format-FailureMessage is fed the SAME raw scalars the caller holds, never
    fields read back out of the payload: Get-FailureEventData applies
    if($X){$X}else{fallback} substitution (e.g. an empty ErrorMessage falls
    back to action / actionVerb), so reading the body's "Error:" line from the
    payload instead of the raw scalar would change the human text for an empty
    error. Forwarding the scalars verbatim keeps the body byte-identical.

    (hostname) is evaluated once here and reused for both the internal
    Get-FailureEventData build path and Format-FailureMessage; every call site
    invokes (hostname) twice today with the same result, so one evaluation is
    behavior-equivalent and drops a redundant process spawn.

    Output hygiene: the Get-FailureEventData and Format-FailureMessage results
    are captured into locals and Send-Notification is the final statement, so
    the helper's pipeline output equals Send-Notification's today and the
    payload hashtable never leaks to the caller's pipeline. When -EventData is
    supplied it wins; the build-path inputs (Default* / ProjectCommit) are then
    ignored, matching how the four internal callers already use the helper.
#>
function Send-CycleFailureNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostType,
        # Subject tail after "Yuruna Test: FAIL on <HostType> / ".
        # GitPull | ProjectClone | "<FailedGuest> / <FailedStep>".
        [Parameter(Mandatory)][string]$SubjectSuffix,
        [string]$GuestKey,
        [string]$StepName,
        [string]$ErrorMessage,
        [string]$CycleId,
        [string]$GitCommit,
        # Pre-built payload (in-cycle / post-loop sites remediate on it before
        # the send). When supplied the internal Get-FailureEventData build is
        # skipped so the shipped payload is byte-identical to the remediated one.
        [hashtable]$EventData = $null,
        # Build-path inputs (bootstrap sites, no last_failure.json yet). Only
        # consulted when -EventData was not supplied. ProjectCommit defaults to
        # '', which Get-FailureEventData treats the same as not passing it.
        [string]$ProjectCommit = '',
        [string]$DefaultFailureClass = 'unknown',
        [string]$DefaultSeverity     = 'unknown'
    )
    $machineName = (hostname)
    $payload = $EventData
    if (-not $payload) {
        $payload = Get-FailureEventData `
            -HostType            $HostType `
            -Hostname            $machineName `
            -GuestKey            $GuestKey `
            -StepName            $StepName `
            -ErrorMessage        $ErrorMessage `
            -CycleId             $CycleId `
            -GitCommit           $GitCommit `
            -ProjectCommit       $ProjectCommit `
            -DefaultFailureClass $DefaultFailureClass `
            -DefaultSeverity     $DefaultSeverity
    }
    $body = Format-FailureMessage `
        -HostType     $HostType `
        -Hostname     $machineName `
        -GuestKey     $GuestKey `
        -StepName     $StepName `
        -ErrorMessage $ErrorMessage `
        -CycleId      $CycleId `
        -GitCommit    $GitCommit `
        -EventData    $payload
    Send-Notification -EventCode    'cycle.failure' `
                      -EventMessage "Yuruna Test: FAIL on $HostType / $SubjectSuffix" `
                      -EventNote    $body `
                      -EventData    $payload
}

Export-ModuleMember -Function Send-Notification, Format-FailureMessage, Get-FailureEventData, Write-NotificationDelivery, Send-CycleFailureNotification
