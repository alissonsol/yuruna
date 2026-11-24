<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4282f2f0-9e32-4d56-aee8-eebcf054b7a1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test web page verbs
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

# The seven page verbs of the sequence engine. Test.SequenceHandler.psm1
# imports this module as its last statement, so every process that loads the
# verb catalog registers the page verbs too. Loading the catalog starts
# nothing: the session module (Test.WebSession.psm1) is imported by the first
# handler that runs, without -Force, so a forced import of the catalog never
# replaces the module that holds live browser sessions. Every failure of a page
# step ends in one account (Set-StepWebFailure) and a $false return; an
# exception that left a handler would be filed as a thrown handler instead.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceAction.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceFailureState.psm1') -Force -Global

# --- REGION: Shared handler steps
function Test-WebStepField {
    <#
    .SYNOPSIS
        Whether a step names a field, whatever its value.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Step,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Step -is [System.Collections.IDictionary]) { return [bool]$Step.Contains($Name) }
    if ($null -eq $Step) { return $false }
    return $null -ne $Step.PSObject.Properties[$Name]
}

function Get-WebStepDeadline {
    <#
    .SYNOPSIS
        The deadline of a page step on the real clock: its timeoutSeconds, else
        the engine default every waiting verb uses.
    .OUTPUTS
        System.DateTime
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [DateTime]::UtcNow.AddSeconds($Context.Step.timeoutSeconds ? [int]$Context.Step.timeoutSeconds : [int]$Context.DefaultTimeoutSeconds)
}

function Get-WebStepLocator {
    <#
    .SYNOPSIS
        The locator a page step names: role and name (with match and nth), or css.
    .DESCRIPTION
        name and css are variable-expanded; role, match and nth are taken as
        written. A locator that cannot run as written throws invalid_step.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $step = $Context.Step
    $locator = [ordered]@{}
    foreach ($field in 'role', 'name', 'match', 'nth', 'css') {
        if (-not (Test-WebStepField -Step $step -Name $field)) { continue }
        $value = $step.$field
        if ($field -eq 'name' -or $field -eq 'css') { $value = [string](& $Context.ExpandVariable $value $Context.Vars) }
        $locator[$field] = $value
    }
    $hasCss = $locator.Contains('css')
    if ($hasCss -and ($locator.Contains('role') -or $locator.Contains('name') -or $locator.Contains('match'))) {
        throw (New-WebFailureException -Kind 'invalid_step' -Detail 'css together with role, name or match')
    }
    if (-not $hasCss -and -not ($locator.Contains('role') -and $locator.Contains('name'))) {
        throw (New-WebFailureException -Kind 'invalid_step' -Detail 'neither css nor role and name')
    }
    if ($hasCss -and -not (ConvertTo-WebName -Text ([string]$locator['css']))) {
        throw (New-WebFailureException -Kind 'invalid_step' -Detail 'empty css')
    }
    if (-not $hasCss -and -not (ConvertTo-WebName -Text ([string]$locator['name']))) {
        throw (New-WebFailureException -Kind 'invalid_step' -Detail 'empty name')
    }
    if ($locator.Contains('match') -and [string]$locator['match'] -cne 'exact' -and [string]$locator['match'] -cne 'contains') {
        throw (New-WebFailureException -Kind 'invalid_step' -Detail "match $($locator['match'])")
    }
    if ($locator.Contains('nth')) {
        $nth = 0
        if (-not [int]::TryParse([string]$locator['nth'], [ref]$nth) -or $nth -lt 1) {
            throw (New-WebFailureException -Kind 'invalid_step' -Detail "nth $($locator['nth'])")
        }
        $locator['nth'] = $nth
    }
    return $locator
}

function Get-WebStepConnection {
    <#
    .SYNOPSIS
        The page connection of the step's VM; invalid_step when no page is open.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $entry = Get-GuestWebSession -VMName $Context.VMName
    if ($null -ne $entry -and (Test-WebCdpOpen -Connection $entry.Cdp)) { return $entry.Cdp }
    throw (New-WebFailureException -Kind 'invalid_step' -Detail 'no page open')
}

function Complete-WebVerbFailure {
    <#
    .SYNOPSIS
        File the account of a failed page step and return $false, or rethrow an
        error that is not a page failure.
    .DESCRIPTION
        A transport failure ends the session, and names an exited browser when
        the session finds its browser gone.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][hashtable]$Effect,
        [Parameter(Mandatory)][datetime]$Started,
        [AllowNull()][System.Collections.IDictionary]$Locator,
        [AllowNull()][hashtable]$Connection
    )
    $failure = $null
    if (Get-Command Get-WebFailureData -ErrorAction SilentlyContinue) { $failure = Get-WebFailureData -ErrorRecord $ErrorRecord }
    if ($null -eq $failure) { throw $ErrorRecord }
    $kind = [string]$failure.Kind
    $detail = [string]$failure.Detail
    if ($kind -eq 'transport') {
        $entry = Get-GuestWebSession -VMName $Context.VMName
        if ($null -ne $entry) {
            $health = Test-GuestWebSession -Session $entry
            if ($health.Code -eq 'browser-exited') { $detail = "browser exited: $detail" }
        }
    }
    $url = if ($null -ne $Connection -and $Connection.Page) { [string]$Connection.Page.Url } else { '' }
    Set-StepWebFailure -Context $Context -Kind $kind -Dispatched ([bool]$Effect.Dispatched) -Acknowledged ([bool]$Effect.Acknowledged) `
        -Locator $Locator -Candidates @($failure.Candidates) -MatchCount ([int]$failure.MatchCount) -Detail $detail `
        -WaitedSeconds ([int][Math]::Floor(([DateTime]::UtcNow - $Started).TotalSeconds)) -Url $url -Title ''
    if ($kind -eq 'transport') {
        [void](Close-GuestWebSession -VMName $Context.VMName -Reason 'web-transport')
    }
    return $false
}

function Format-WebStepLabel {
    <#
    .SYNOPSIS
        The failure label of a page step: the verb and what it sought, never a
        typed value.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $step = $Context.Step
    $verb = [string]$step.action
    $expand = { param($Value) [string](& $Context.ExpandVariable $Value $Context.Vars) }
    switch ($verb) {
        'webOpen' { return "webOpen: $(& $expand $step.url)" }
        'webPress' { return "webPress: $($step.key)" }
        'webClose' { return 'webClose' }
    }
    $gone = if ($verb -eq 'webExpect' -and $step.gone -eq $true) { ' gone' } else { '' }
    if ($verb -eq 'webExpect' -and (Test-WebStepField -Step $step -Name 'text')) {
        $shown = if ($step.sensitive) { '***' } else { & $expand $step.text }
        return "webExpect: text `"$shown`"$gone"
    }
    $label = if (Test-WebStepField -Step $step -Name 'css') {
        "${verb}: css `"$(& $expand $step.css)`""
    } else {
        "${verb}: $($step.role) `"$(& $expand $step.name)`""
    }
    if (Test-WebStepField -Step $step -Name 'nth') { $label += " nth $($step.nth)" }
    if ($verb -eq 'webSelect') { $label += " option `"$(& $expand $step.option)`"" }
    return $label + $gone
}

# --- REGION: Page verbs
# webOpen opens the guest's page; the other verbs act on the page it opened.
# The browser runs in the guest, so http://localhost:8080/ names the guest.
Register-SequenceAction -Name 'webOpen' -ReplaySafety 'state-changing' -HostIORequirement @() -HostCommandRequirement @('ssh', 'ssh-keygen') -OcrRequired $false `
    -FailureClass 'web_step_failed' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.verb_web_open') `
    -FailureLabel { param($c) Format-WebStepLabel -Context $c } `
    -Handler {
        param([hashtable]$c)
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $started = [DateTime]::UtcNow
        $locator = $null; $connection = $null
        try {
            if (-not (Get-Command Get-GuestWebSession -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Global -DisableNameChecking }
            $deadline = Get-WebStepDeadline -Context $c
            $url = [string](& $c.ExpandVariable $c.Step.url $c.Vars)
            $parsed = $null
            if ($url -cne 'about:blank' -and -not ([uri]::TryCreate($url, 'Absolute', [ref]$parsed) -and ($parsed.Scheme -eq 'http' -or $parsed.Scheme -eq 'https'))) {
                throw (New-WebFailureException -Kind 'invalid_step' -Detail 'url')
            }
            Write-Debug "      webOpen: $url"
            $entry = Get-GuestWebSession -VMName $c.VMName
            if ($null -eq $entry -or -not (Test-GuestWebSession -Session $entry).Alive) {
                $open = Open-GuestWebSession -VMName $c.VMName -GuestKey $c.GuestKey -OwnerId ([string]$c.SequenceInvocationId) -DeadlineUtc $deadline -Effect $effect
                if (-not $open.Ok) { throw (New-WebFailureException -Kind $open.Kind -Detail $open.Detail) }
                $entry = $open.Session
            }
            if (-not (Test-WebCdpOpen -Connection $entry.Cdp)) {
                if ($entry.Cdp) { Close-WebCdp -Connection $entry.Cdp }
                # Stored at once, so every later failure leaves the connection
                # where the close of the session finds it.
                $entry.Cdp = Connect-WebCdp -Port $entry.LocalPort -DeadlineUtc $deadline
                Open-WebCdpPage -Connection $entry.Cdp -DeadlineUtc $deadline
            }
            $connection = $entry.Cdp
            $null = Invoke-WebPageOpen -Connection $connection -Url $url -DeadlineUtc $deadline -Effect $effect
            return $true
        } catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { return (Complete-WebVerbFailure -Context $c -ErrorRecord $_ -Effect $effect `
                -Started $started -Locator $locator -Connection $connection) }
    }

Register-SequenceAction -Name 'webClick' -ReplaySafety 'input' -HostIORequirement @() -HostCommandRequirement @('ssh', 'ssh-keygen') -OcrRequired $false `
    -FailureClass 'web_step_failed' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.verb_web_click') `
    -FailureLabel { param($c) Format-WebStepLabel -Context $c } `
    -Handler {
        param([hashtable]$c)
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $started = [DateTime]::UtcNow
        $locator = $null; $connection = $null
        try {
            if (-not (Get-Command Get-GuestWebSession -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Global -DisableNameChecking }
            $deadline = Get-WebStepDeadline -Context $c
            $locator = Get-WebStepLocator -Context $c
            $connection = Get-WebStepConnection -Context $c
            Write-Debug "      webClick: $($locator['role'])$($locator['css']) `"$($locator['name'])`""
            $clickArguments = @{ Connection = $connection; Locator = $locator; DeadlineUtc = $deadline; Effect = $effect }
            if (Test-WebStepField -Step $c.Step -Name 'checked') { $clickArguments['Checked'] = [bool]$c.Step.checked }
            $null = Invoke-WebPageClick @clickArguments
            return $true
        } catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { return (Complete-WebVerbFailure -Context $c -ErrorRecord $_ -Effect $effect `
                -Started $started -Locator $locator -Connection $connection) }
    }

Register-SequenceAction -Name 'webFill' -ReplaySafety 'input' -HostIORequirement @() -HostCommandRequirement @('ssh', 'ssh-keygen') -OcrRequired $false `
    -FailureClass 'web_step_failed' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.verb_web_fill') `
    -FailureLabel { param($c) Format-WebStepLabel -Context $c } `
    -Handler {
        param([hashtable]$c)
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $started = [DateTime]::UtcNow
        $locator = $null; $connection = $null
        try {
            if (-not (Get-Command Get-GuestWebSession -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Global -DisableNameChecking }
            $deadline = Get-WebStepDeadline -Context $c
            $locator = Get-WebStepLocator -Context $c
            $connection = Get-WebStepConnection -Context $c
            $text = [string](& $c.ExpandVariable $c.Step.text $c.Vars)
            $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
            Write-Debug "      webFill: $($locator['role'])$($locator['css']) `"$($locator['name'])`" with '$masked'"
            $null = Invoke-WebPageFill -Connection $connection -Locator $locator -Text $text -DeadlineUtc $deadline -Effect $effect
            return $true
        } catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { return (Complete-WebVerbFailure -Context $c -ErrorRecord $_ -Effect $effect `
                -Started $started -Locator $locator -Connection $connection) }
    }

Register-SequenceAction -Name 'webSelect' -ReplaySafety 'input' -HostIORequirement @() -HostCommandRequirement @('ssh', 'ssh-keygen') -OcrRequired $false `
    -FailureClass 'web_step_failed' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.verb_web_select') `
    -FailureLabel { param($c) Format-WebStepLabel -Context $c } `
    -Handler {
        param([hashtable]$c)
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $started = [DateTime]::UtcNow
        $locator = $null; $connection = $null
        try {
            if (-not (Get-Command Get-GuestWebSession -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Global -DisableNameChecking }
            $deadline = Get-WebStepDeadline -Context $c
            $locator = Get-WebStepLocator -Context $c
            $connection = Get-WebStepConnection -Context $c
            $option = [string](& $c.ExpandVariable $c.Step.option $c.Vars)
            if (-not (ConvertTo-WebName -Text $option)) { throw (New-WebFailureException -Kind 'invalid_step' -Detail 'empty option') }
            Write-Debug "      webSelect: $($locator['role'])$($locator['css']) `"$($locator['name'])`" option `"$option`""
            $null = Invoke-WebPageSelect -Connection $connection -Locator $locator -Option $option -DeadlineUtc $deadline -Effect $effect
            return $true
        } catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { return (Complete-WebVerbFailure -Context $c -ErrorRecord $_ -Effect $effect `
                -Started $started -Locator $locator -Connection $connection) }
    }

Register-SequenceAction -Name 'webPress' -ReplaySafety 'input' -HostIORequirement @() -HostCommandRequirement @('ssh', 'ssh-keygen') -OcrRequired $false `
    -FailureClass 'web_step_failed' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.verb_web_press') `
    -FailureLabel { param($c) Format-WebStepLabel -Context $c } `
    -Handler {
        param([hashtable]$c)
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $started = [DateTime]::UtcNow
        $locator = $null; $connection = $null
        try {
            if (-not (Get-Command Get-GuestWebSession -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Global -DisableNameChecking }
            $deadline = Get-WebStepDeadline -Context $c
            $connection = Get-WebStepConnection -Context $c
            # The key name is taken as written, never variable-expanded.
            $key = [string]$c.Step.key
            Write-Debug "      webPress: $key"
            $null = Invoke-WebPagePress -Connection $connection -Key $key -DeadlineUtc $deadline -Effect $effect
            return $true
        } catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { return (Complete-WebVerbFailure -Context $c -ErrorRecord $_ -Effect $effect `
                -Started $started -Locator $locator -Connection $connection) }
    }

Register-SequenceAction -Name 'webExpect' -ReplaySafety 'observe' -HostIORequirement @() -HostCommandRequirement @('ssh', 'ssh-keygen') -OcrRequired $false `
    -FailureClass 'web_step_failed' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.verb_web_expect') `
    -FailureLabel { param($c) Format-WebStepLabel -Context $c } `
    -Handler {
        param([hashtable]$c)
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $started = [DateTime]::UtcNow
        $locator = $null; $connection = $null
        try {
            if (-not (Get-Command Get-GuestWebSession -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Global -DisableNameChecking }
            $deadline = Get-WebStepDeadline -Context $c
            $gone = $c.Step.gone -eq $true
            if (Test-WebStepField -Step $c.Step -Name 'text') {
                foreach ($field in 'role', 'name', 'match', 'nth', 'css') {
                    if (Test-WebStepField -Step $c.Step -Name $field) {
                        throw (New-WebFailureException -Kind 'invalid_step' -Detail "text together with $field")
                    }
                }
                $text = [string](& $c.ExpandVariable $c.Step.text $c.Vars)
                if (-not (ConvertTo-WebName -Text $text)) { throw (New-WebFailureException -Kind 'invalid_step' -Detail 'empty text') }
                # The sought text is the one locator that carries text into the
                # failure account, masked there for a sensitive step.
                $locator = [ordered]@{ text = $text }
                $connection = Get-WebStepConnection -Context $c
                $shown = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
                Write-Debug "      webExpect: text `"$shown`"$(if ($gone) { ' gone' })"
                $null = Invoke-WebPageExpect -Connection $connection -Text $text -Gone:$gone -DeadlineUtc $deadline
            } else {
                $locator = Get-WebStepLocator -Context $c
                $connection = Get-WebStepConnection -Context $c
                Write-Debug "      webExpect: $($locator['role'])$($locator['css']) `"$($locator['name'])`"$(if ($gone) { ' gone' })"
                $null = Invoke-WebPageExpect -Connection $connection -Locator $locator -Gone:$gone -DeadlineUtc $deadline
            }
            return $true
        } catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { return (Complete-WebVerbFailure -Context $c -ErrorRecord $_ -Effect $effect `
                -Started $started -Locator $locator -Connection $connection) }
    }

Register-SequenceAction -Name 'webClose' -ReplaySafety 'state-changing' -HostIORequirement @() -HostCommandRequirement @('ssh', 'ssh-keygen') -OcrRequired $false `
    -FailureClass 'web_step_failed' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.verb_web_close') `
    -FailureLabel { param($c) Format-WebStepLabel -Context $c } `
    -Handler {
        param([hashtable]$c)
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $started = [DateTime]::UtcNow
        $locator = $null; $connection = $null
        try {
            if (-not (Get-Command Get-GuestWebSession -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Global -DisableNameChecking }
            # No page open is not a failure: a sequence needs no closing step.
            if ($null -eq (Get-GuestWebSession -VMName $c.VMName)) { return $true }
            Write-Debug '      webClose'
            $effect.Dispatched = $true
            [void](Close-GuestWebSession -VMName $c.VMName -Reason 'web-close')
            $effect.Acknowledged = $true
            return $true
        } catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { return (Complete-WebVerbFailure -Context $c -ErrorRecord $_ -Effect $effect `
                -Started $started -Locator $locator -Connection $connection) }
    }

# No Export-ModuleMember: the public surface of this module is the
# Register-SequenceAction calls above, which write into the Test.SequenceAction
# registry the engine reads.
