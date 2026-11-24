<#PSScriptInfo
.VERSION 2026.11.23
.GUID 429fa133-c15e-4841-af1b-b9e9d103e60e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload session executor
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

# The worker side of a workload authoring session: the handler of every
# method the worker shell serves, the session variables, the checks a step or
# an action passes before it runs, the executor that runs it through
# Invoke-Sequence itself, the journal, the failure view and the screen
# snapshot. The engine, the planner and the host driver are loaded once, by
# the session start (Import-WorkloadEngineModule), and are called here by
# name: importing them from this module would replace the engine module under
# a running session. Everything this module returns or writes into the session
# folder passes the secret filter first.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceSecret.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.LocalizationExchange.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.WorkloadRuntime.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.WorkloadSequenceFile.psm1') -Global -DisableNameChecking

# The same pattern Protect-GuestEvidenceText (Test.Diagnostic.psm1) uses to
# decide that a variable holds a secret.
$script:WorkloadSecretNamePattern = '(?i)password|passwd|secret|token|credential|private.?key'
$script:WorkloadExtensionPattern = '\$\{ext:([A-Za-z0-9_-]+)\.([A-Za-z][A-Za-z0-9_-]*)\(([^)]*)\)\}'
$script:WorkloadVariablePattern = '\$\{([^}]+)\}'
$script:WorkloadSingleTokenPattern = '^(?:\$\{ext:([A-Za-z0-9_-]+)\.([A-Za-z][A-Za-z0-9_-]*)\(([^)]*)\)\}|\$\{([^}:]+)\})$'
$script:WorkloadDollarSentinel = [string][char]0xE000
$script:WorkloadSecretMinimumLength = 4
$script:WorkloadMaxStepChars = 16384
$script:WorkloadReservedField = @('action', 'description', 'descriptionLocalized', 'fromStep', 'step', 'snippet', 'steps', 'stepsAfterVmRestart', 'on')
$script:WorkloadReservedVariable = @('vmName', 'hostType', 'guestKey')
$script:WorkloadScopeVariable = @('vmName', 'hostType', 'guestKey', 'hostname')
# The parsed sequence schema, keyed by its path, write time and length.
$script:WorkloadSchemaCache = @{ Key = $null; Document = $null }
# Per engine.log path: the characters written so far and whether the limit was reached.
$script:WorkloadEngineLogState = @{}

function ConvertTo-WorkloadUtcText {
    <#
    .SYNOPSIS
        An instant as the UTC text every journal entry and result carries.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Instant)
    return $Instant.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-WorkloadTokenScan {
    <#
    .SYNOPSIS
        The extension tokens and the variable names of one text, with an escaped $$ hidden.
    .DESCRIPTION
        $$ is hidden first, as Expand-Variable hides it, so an escaped token
        is no token. Extension tokens are removed before the variable tokens
        are read, so the arguments of an extension call are not counted.
        SingleToken holds when the whole text is one extension token or one
        variable token; SingleVariable names that variable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $hidden = ([string]$Text).Replace('$$', $script:WorkloadDollarSentinel)
    $extensions = @([regex]::Matches($hidden, $script:WorkloadExtensionPattern) | ForEach-Object { [string]$_.Groups[1].Value })
    $rest = [regex]::Replace($hidden, $script:WorkloadExtensionPattern, '')
    $variables = @([regex]::Matches($rest, $script:WorkloadVariablePattern) | ForEach-Object { [string]$_.Groups[1].Value })
    $single = [regex]::Match($hidden, $script:WorkloadSingleTokenPattern)
    return @{
        ExtensionArea  = $extensions
        Variable       = $variables
        SingleToken    = $single.Success
        SingleVariable = $(if ($single.Success -and $single.Groups[4].Success) { [string]$single.Groups[4].Value } else { $null })
    }
}

function Get-WorkloadStringValue {
    <#
    .SYNOPSIS
        Every string inside a value, recursively, in order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($null -eq $Value -or $Depth -gt 32) { return }
    if ($Value -is [string]) { $Value; return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) { Get-WorkloadStringValue -Value $Value[$key] -Depth ($Depth + 1) }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { Get-WorkloadStringValue -Value $item -Depth ($Depth + 1) }
    }
}

function Get-WorkloadMaskFailedCount {
    <#
    .SYNOPSIS
        How many values the front end has not confirmed so far in this process.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int](Get-SequenceSecretStat).maskFailed
}

function ConvertTo-WorkloadOperationRefusal {
    <#
    .SYNOPSIS
        The answer to an operation refused before dispatch, from a refusal.
    .DESCRIPTION
        Nothing ran, so the effect is none-proven; nothing is journaled and no
        sequence number is consumed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Refusal)
    return [ordered]@{
        ok         = $false
        state      = 'failed'
        dispatched = $false
        effect     = 'none-proven'
        journaled  = $false
        error      = $Refusal['error']
    }
}

function Initialize-WorkloadVariableScope {
    <#
    .SYNOPSIS
        Builds the session's variable table once; $null, or a refusal.
    .DESCRIPTION
        The first call for a session (the session has no Journal yet) switches
        the secret filter on, reads the unexpanded variables of the source
        sequence's chain with Resolve-NamedSequenceChain (never the planner,
        which can remove a VM), lays the client's variables over them, and
        creates the session keys this module owns. Every call then expands the
        table once with New-SequenceVariableScope, follows the user name into
        the SSH user and clears the carried console baseline. A later call
        reuses RawVariables, so a value an extension produces stays the same
        until the next rebuild. An exception of the chain resolver propagates.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'Results is keyed by operation id, which is compared ordinally everywhere else; a literal hashtable ignores case.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [AllowEmptyString()][string]$Sequence,
        [AllowNull()][System.Collections.IDictionary]$Variables
    )
    $maskBefore = Get-WorkloadMaskFailedCount
    if (-not $Session.ContainsKey('Journal')) {
        Enable-SequenceSecretFilter
        $raw = [ordered]@{}
        if ($Sequence) {
            $chainName = if ([string]$Session.SourceSequence) { [string]$Session.SourceSequence } else { [IO.Path]::GetFileNameWithoutExtension($Sequence) }
            $chain = Resolve-NamedSequenceChain -RepoRoot $Session.RepoRoot -SequencesDir $Session.SequencesDir -HostType $Session.HostType `
                -SequenceName $chainName -OsKey $Session.OsKey -TopLevelPath $Sequence
            $effective = $chain.effectiveVariables
            if ($effective -is [System.Collections.IDictionary]) {
                foreach ($key in @($effective.Keys)) { $raw[$key] = $effective[$key] }
            }
        }
        if ($null -ne $Variables) {
            foreach ($key in @($Variables.Keys)) {
                $name = [string]$key
                if ($script:WorkloadReservedVariable -contains $name) {
                    return (New-WorkloadRefusal -Code 'workload_variable_reserved' -Key 'runner.workload_variable_reserved' -Arguments @{ name = $name })
                }
            }
            foreach ($key in @($Variables.Keys)) {
                $name = [string]$key
                $value = $Variables[$key]
                if ($name -match $script:WorkloadSecretNamePattern) {
                    $reference = $false
                    if ($value -is [string]) {
                        $scan = Get-WorkloadTokenScan -Text $value
                        if ($scan.SingleToken) {
                            $reference = ($null -eq $scan.SingleVariable) -or $raw.Contains($scan.SingleVariable) -or
                                ($script:WorkloadScopeVariable -contains $scan.SingleVariable)
                        }
                    }
                    if (-not $reference) {
                        return (New-WorkloadRefusal -Code 'workload_secret_reference_required' -Key 'runner.workload_secret_reference_required' -Arguments @{ field = $name })
                    }
                }
                $raw[$name] = $value
            }
        }
        $Session.RawVariables = $raw
        $Session.OperationSeq = 0
        $Session.Journal = [Collections.Generic.List[object]]::new()
        # Ordinal, so two operation ids that differ only in letter case never share a result.
        $Session.Results = [hashtable]::new([StringComparer]::Ordinal)
        $Session.SensitiveState = $false
        $Session.SensitiveSinceSeq = 0
        $Session.LastFailure = $null
        $Session.PhraseLibrary = $null
    }

    $holder = @{}
    $call = Invoke-WorkloadEngineCall -Session $Session -ScriptBlock ({
            $holder.Vars = New-SequenceVariableScope -VMName $Session.VMName -HostType $Session.HostType -GuestKey $Session.GuestKey `
                -SequenceVariables $null -EffectiveVariables $Session.RawVariables
        }.GetNewClosure())
    if ($null -ne $call.Error) {
        return (New-WorkloadRefusal -Code 'workload_variables_failed' -Key 'runner.workload_variables_failed' -Arguments @{ detail = [string]$call.Error })
    }
    $Session.Vars = $holder.Vars
    foreach ($key in @($Session.Vars.Keys)) {
        $value = $Session.Vars[$key]
        if ([string]$key -match $script:WorkloadSecretNamePattern -and $value -is [string] -and
            $value.Length -gt 0 -and $value.Length -lt $script:WorkloadSecretMinimumLength) {
            return (New-WorkloadRefusal -Code 'workload_secret_too_short' -Key 'runner.workload_secret_too_short' -Arguments @{
                    name = [string]$key; minimum = $script:WorkloadSecretMinimumLength })
        }
    }
    Clear-GuestSshUserOverride
    $username = $Session.Vars['username']
    if ($username -is [string] -and $username.Length -gt 0) {
        Set-GuestSshUserOverride -GuestKey $Session.GuestKey -Username ([string]$username)
    }
    Clear-CarriedConsoleBaseline
    if ((Get-WorkloadMaskFailedCount) -gt $maskBefore) {
        return (New-WorkloadRefusal -Code 'workload_mask_failed' -Key 'runner.workload_mask_failed')
    }
    return $null
}

function Test-WorkloadVerb {
    <#
    .SYNOPSIS
        $null when a session may run the verb, else the refusal that names why not.
    .DESCRIPTION
        The first that applies: a name that is not registered; an alias or
        another letter case of a registered name; a verb that changes the
        power state or the name of the VM; a verb that waits for an operator;
        a verb that wraps other steps; a verb without a replay class.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Action)
    if ([string]::IsNullOrEmpty($Action) -or -not (Test-SequenceActionHasHandler -Name $Action)) {
        return (New-WorkloadRefusal -Code 'workload_verb_unregistered' -Key 'runner.workload_verb_unregistered' -Arguments @{ action = $Action })
    }
    $entry = Get-SequenceAction -Name $Action
    $canonical = [string]$entry.Name
    if (-not [string]::Equals($canonical, $Action, [StringComparison]::Ordinal)) {
        return (New-WorkloadRefusal -Code 'workload_verb_alias' -Key 'runner.workload_verb_alias' -Arguments @{ action = $Action; canonical = $canonical })
    }
    if ($Action -cin @('startVm', 'stopVm', 'saveDiskSnapshot', 'loadDiskSnapshot', 'recoverFromSnapshot')) {
        return (New-WorkloadRefusal -Code 'workload_verb_denied_vm_state' -Key 'runner.workload_verb_denied_vm_state' -Arguments @{ action = $Action })
    }
    if ($Action -ceq 'break') {
        return (New-WorkloadRefusal -Code 'workload_verb_denied_operator_hold' -Key 'runner.workload_verb_denied_operator_hold' -Arguments @{ action = $Action })
    }
    if ($Action -ceq 'retry') {
        return (New-WorkloadRefusal -Code 'workload_verb_denied_composite' -Key 'runner.workload_verb_denied_composite' -Arguments @{ action = $Action })
    }
    if ((Get-SequenceActionReplaySafety -Name $Action) -ceq 'unclassified') {
        return (New-WorkloadRefusal -Code 'workload_verb_denied_unclassified' -Key 'runner.workload_verb_denied_unclassified' -Arguments @{ action = $Action })
    }
    return $null
}

function Get-WorkloadAllowedVerb {
    <#
    .SYNOPSIS
        The registered verbs a session may run, sorted ordinally.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    $allowed = [Collections.Generic.List[string]]::new()
    foreach ($name in @(Get-SequenceActionName)) {
        if ($null -eq (Test-WorkloadVerb -Action ([string]$name))) { $allowed.Add([string]$name) }
    }
    $sorted = $allowed.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return , ([string[]]$sorted)
}

function Get-WorkloadSchemaDocument {
    <#
    .SYNOPSIS
        The sequence schema, parsed once per version of the file.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()
    $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../schemas/sequence.schema.yml'))
    $item = Get-Item -LiteralPath $path
    $key = '{0}|{1}|{2}' -f $path, $item.LastWriteTimeUtc.Ticks, $item.Length
    if ($script:WorkloadSchemaCache.Key -cne $key) {
        Assert-LocalizationYamlCodec
        $script:WorkloadSchemaCache.Document = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($path)) -Ordered
        $script:WorkloadSchemaCache.Key = $key
    }
    return $script:WorkloadSchemaCache.Document
}

function Test-WorkloadActionField {
    <#
    .SYNOPSIS
        Checks the fields of a workload_action against the verb's branch of the sequence schema.
    .DESCRIPTION
        Returns @{ Refusal; Warnings }. A reserved field, a required field that
        is missing and a declared field of the wrong type are refused, each
        named. A field the branch does not declare runs with a warning, as a
        replay would pass it, because the branches are not a complete field
        contract.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Action,
        [AllowNull()][System.Collections.IDictionary]$Fields
    )
    $warnings = [Collections.Generic.List[object]]::new()
    $names = @(if ($null -ne $Fields) { $Fields.Keys | ForEach-Object { [string]$_ } })
    foreach ($name in $names) {
        if ($script:WorkloadReservedField -contains $name) {
            return @{ Refusal = (New-WorkloadRefusal -Code 'workload_field_reserved' -Key 'runner.workload_field_reserved' -Arguments @{ field = $name }); Warnings = $warnings }
        }
    }
    $schema = Get-WorkloadSchemaDocument
    $defs = $schema['$defs']
    $actionStep = $defs['actionStep']
    if (@($actionStep['properties']['action']['enum']) -cnotcontains $Action) {
        return @{ Refusal = (New-WorkloadRefusal -Code 'workload_verb_unregistered' -Key 'runner.workload_verb_unregistered' -Arguments @{ action = $Action }); Warnings = $warnings }
    }
    $clauses = @($actionStep['allOf'])
    $index = -1
    for ($i = 0; $i -lt $clauses.Count; $i++) {
        $condition = $clauses[$i]['if']
        if ($condition -isnot [System.Collections.IDictionary] -or $condition['properties'] -isnot [System.Collections.IDictionary]) { continue }
        $match = $condition['properties']['action']
        if ($match -isnot [System.Collections.IDictionary]) { continue }
        if (($match.Contains('const') -and [string]$match['const'] -ceq $Action) -or
            ($match.Contains('enum') -and @($match['enum']) -ccontains $Action)) { $index = $i; break }
    }
    $declared = @()
    if ($index -ge 0) {
        $then = $clauses[$index]['then']
        if ($then -is [System.Collections.IDictionary]) {
            foreach ($required in @($then['required'])) {
                if ($null -ne $required -and $names -cnotcontains [string]$required) {
                    return @{ Refusal = (New-WorkloadRefusal -Code 'workload_field_missing' -Key 'runner.workload_field_missing' -Arguments @{ action = $Action; field = [string]$required }); Warnings = $warnings }
                }
            }
            if ($then['properties'] -is [System.Collections.IDictionary]) { $declared = @($then['properties'].Keys | ForEach-Object { [string]$_ }) }
            foreach ($name in $names) {
                if ($declared -cnotcontains $name) { continue }
                $fieldSchema = [ordered]@{
                    '$schema' = $schema['$schema']
                    '$ref'    = "#/`$defs/actionStep/allOf/$index/then/properties/$name"
                    '$defs'   = $defs
                }
                $fieldError = Get-YurunaJsonSchemaError -Json (ConvertTo-Json -InputObject $Fields[$name] -Depth 32) -Schema (ConvertTo-Json -InputObject $fieldSchema -Depth 32)
                if ($fieldError) {
                    return @{ Refusal = (New-WorkloadRefusal -Code 'workload_field_invalid' -Key 'runner.workload_field_invalid' -Arguments @{ action = $Action; field = $name; detail = [string]$fieldError }); Warnings = $warnings }
                }
            }
        }
    }
    foreach ($name in $names) {
        if ($declared -ccontains $name -or $name -ceq 'sensitive') { continue }
        $warnings.Add([ordered]@{
                code    = 'workload_field_undeclared'
                message = (Format-YurunaOperatorMessage -Key 'runner.workload_field_undeclared' -Arguments @{ action = $Action; field = $name })
            })
    }
    $step = [ordered]@{ action = $Action }
    foreach ($name in $names) { $step[$name] = $Fields[$name] }
    $stepSchema = [ordered]@{ '$schema' = $schema['$schema']; '$ref' = '#/$defs/actionStep'; '$defs' = $defs }
    $stepError = Get-YurunaJsonSchemaError -Json (ConvertTo-Json -InputObject $step -Depth 32) -Schema (ConvertTo-Json -InputObject $stepSchema -Depth 32)
    if ($stepError) {
        return @{ Refusal = (New-WorkloadRefusal -Code 'workload_field_invalid' -Key 'runner.workload_field_invalid' -Arguments @{ action = $Action; field = 'action'; detail = [string]$stepError }); Warnings = $warnings }
    }
    return @{ Refusal = $null; Warnings = $warnings }
}

function Test-WorkloadSecretInput {
    <#
    .SYNOPSIS
        Checks where a request carries secrets; returns @{ Refusal; SecretInput; SecretVariable }.
    .DESCRIPTION
        A request that repeats a value the session registered is refused
        without echoing it. A secret field (the text, else the command, of a
        sensitive step or of a passwdPrompt action, and the currentPassword and
        newPassword of an sshWaitReady step) must refer to its secret through
        known variable or extension tokens; a passwdPrompt text and each
        sshWaitReady password hold one token and nothing else. SecretVariable lists the variables those
        fields name, so the caller registers them before dispatch. Pure: no
        message holds a field value.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps,
        [AllowEmptyCollection()][AllowNull()][string[]]$ClientText
    )
    $answer = @{ Refusal = $null; SecretInput = $false; SecretVariable = [string[]]@() }
    foreach ($text in @($ClientText)) {
        if (Test-SequenceSecretText -Text $text) {
            $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_literal' -Key 'runner.workload_secret_literal'
            return $answer
        }
    }
    $vars = $Session.Vars
    $secretNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $secretInput = $false
    foreach ($step in $Steps) {
        if ($step -isnot [System.Collections.IDictionary]) { continue }
        $bearing = ($step['sensitive'] -eq $true) -or ($Tool -ceq 'workload_action' -and [string]$step['action'] -ceq 'passwdPrompt')
        if ($bearing) {
            $secretInput = $true
            $field = $null
            if ($step.Contains('text') -and $null -ne $step['text']) { $field = 'text' }
            elseif ($step.Contains('command') -and $null -ne $step['command']) { $field = 'command' }
            if ($null -eq $field) {
                $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_reference_required' -Key 'runner.workload_secret_reference_required' -Arguments @{ field = 'text' }
                return $answer
            }
            $scan = Get-WorkloadTokenScan -Text ([string]$step[$field])
            foreach ($name in $scan.Variable) {
                if ($null -eq $vars -or -not $vars.ContainsKey($name)) {
                    $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_variable_unknown' -Key 'runner.workload_secret_variable_unknown' -Arguments @{ field = $field; name = $name }
                    return $answer
                }
            }
            if (($scan.Variable.Count + $scan.ExtensionArea.Count) -eq 0) {
                $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_reference_required' -Key 'runner.workload_secret_reference_required' -Arguments @{ field = $field }
                return $answer
            }
            if ([string]$step['action'] -ceq 'passwdPrompt' -and -not $scan.SingleToken) {
                $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_reference_required' -Key 'runner.workload_secret_reference_required' -Arguments @{ field = $field }
                return $answer
            }
            foreach ($name in $scan.Variable) {
                $value = $vars[$name]
                if ($value -is [string] -and $value.Length -gt 0 -and $value.Length -lt $script:WorkloadSecretMinimumLength) {
                    $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_too_short' -Key 'runner.workload_secret_too_short' -Arguments @{
                        name = $name; minimum = $script:WorkloadSecretMinimumLength }
                    return $answer
                }
                $null = $secretNames.Add($name)
            }
        }
        # The two password fields of sshWaitReady are secret on every tool, and
        # each holds one reference and nothing else, as a passwdPrompt text does.
        if ([string]$step['action'] -ceq 'sshWaitReady') {
            foreach ($field in @('currentPassword', 'newPassword')) {
                if (-not $step.Contains($field) -or $null -eq $step[$field]) { continue }
                $secretInput = $true
                $scan = Get-WorkloadTokenScan -Text ([string]$step[$field])
                foreach ($name in $scan.Variable) {
                    if ($null -eq $vars -or -not $vars.ContainsKey($name)) {
                        $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_variable_unknown' -Key 'runner.workload_secret_variable_unknown' -Arguments @{ field = $field; name = $name }
                        return $answer
                    }
                }
                if (-not $scan.SingleToken) {
                    $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_reference_required' -Key 'runner.workload_secret_reference_required' -Arguments @{ field = $field }
                    return $answer
                }
                foreach ($name in $scan.Variable) {
                    $value = $vars[$name]
                    if ($value -is [string] -and $value.Length -gt 0 -and $value.Length -lt $script:WorkloadSecretMinimumLength) {
                        $answer.Refusal = New-WorkloadRefusal -Code 'workload_secret_too_short' -Key 'runner.workload_secret_too_short' -Arguments @{
                            name = $name; minimum = $script:WorkloadSecretMinimumLength }
                        return $answer
                    }
                    $null = $secretNames.Add($name)
                }
            }
        }
        foreach ($text in @(Get-WorkloadStringValue -Value $step)) {
            $scan = Get-WorkloadTokenScan -Text $text
            if (@($scan.ExtensionArea | Where-Object { $_ -eq 'authentication' }).Count -gt 0) { $secretInput = $true }
            foreach ($name in $scan.Variable) {
                if ($null -ne $vars -and $vars.ContainsKey($name) -and $vars[$name] -is [string] -and (Test-SequenceSecretText -Text ([string]$vars[$name]))) {
                    $secretInput = $true
                }
            }
        }
    }
    $sorted = [string[]]@($secretNames)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $answer.SecretVariable = $sorted
    $answer.SecretInput = $secretInput
    return $answer
}

function Test-WorkloadIntent {
    <#
    .SYNOPSIS
        $null for an intent of one line of 1 to 200 characters without a variable token, else a refusal.
    .DESCRIPTION
        The intent becomes the step's description, which the engine expands
        as a template, so a token there would be evaluated and printed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowEmptyString()][AllowNull()][string]$Intent)
    $valid = -not [string]::IsNullOrEmpty($Intent) -and $Intent.Length -le 200 -and -not $Intent.Contains('${', [StringComparison]::Ordinal)
    if ($valid) {
        foreach ($character in $Intent.ToCharArray()) {
            if ([int]$character -lt 0x20 -or [int]$character -eq 0x7F) { $valid = $false; break }
        }
    }
    if ($valid) { return $null }
    return (New-WorkloadRefusal -Code 'workload_intent_invalid' -Key 'runner.workload_intent_invalid')
}

function Test-WorkloadYamlValueEqual {
    <#
    .SYNOPSIS
        Whether a value read back from YAML equals the value written, kind for kind.
    .DESCRIPTION
        Maps hold the same keys in the same order; strings are equal
        ordinally and still strings; booleans still booleans; numbers equal as
        decimals; lists element by element.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Expected, [AllowNull()]$Actual)
    if ($null -eq $Expected -or $null -eq $Actual) { return ($null -eq $Expected -and $null -eq $Actual) }
    if ($Expected -is [string]) { return ($Actual -is [string] -and [string]::Equals($Expected, $Actual, [StringComparison]::Ordinal)) }
    if ($Expected -is [bool]) { return ($Actual -is [bool] -and $Expected -eq $Actual) }
    $numeric = { param($v) $v -is [byte] -or $v -is [int16] -or $v -is [int] -or $v -is [long] -or $v -is [uint32] -or $v -is [uint64] -or
        $v -is [decimal] -or $v -is [double] -or $v -is [single] -or $v -is [System.Numerics.BigInteger] }
    if (& $numeric $Expected) {
        if (-not (& $numeric $Actual)) { return $false }
        try {
            return ([decimal]$Expected -eq [decimal]$Actual)
        } catch {
            Write-Verbose "A number does not convert to a decimal for the comparison: $($_.Exception.Message)"
            return $false
        }
    }
    if ($Expected -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary] -or $Expected.Count -ne $Actual.Count) { return $false }
        $expectedKeys = @($Expected.Keys)
        $actualKeys = @($Actual.Keys)
        for ($i = 0; $i -lt $expectedKeys.Count; $i++) {
            if (-not [string]::Equals([string]$expectedKeys[$i], [string]$actualKeys[$i], [StringComparison]::Ordinal)) { return $false }
            if (-not (Test-WorkloadYamlValueEqual -Expected $Expected[$expectedKeys[$i]] -Actual $Actual[$actualKeys[$i]])) { return $false }
        }
        return $true
    }
    if ($Expected -is [System.Collections.IEnumerable]) {
        if ($Actual -is [string] -or $Actual -is [System.Collections.IDictionary] -or $Actual -isnot [System.Collections.IEnumerable]) { return $false }
        $expectedItems = @($Expected)
        $actualItems = @($Actual)
        if ($expectedItems.Count -ne $actualItems.Count) { return $false }
        for ($i = 0; $i -lt $expectedItems.Count; $i++) {
            if (-not (Test-WorkloadYamlValueEqual -Expected $expectedItems[$i] -Actual $actualItems[$i])) { return $false }
        }
        return $true
    }
    return $false
}

function ConvertTo-WorkloadStepYaml {
    <#
    .SYNOPSIS
        The YAML text of an authored step, proven to read back unchanged; returns @{ Text; Refusal }.
    .DESCRIPTION
        The text comes from the serializer the saved file uses, so the ran
        text of a result is the text a save writes. A step that the serializer
        refuses, that is too large or that does not read back equal is
        refused, and so never runs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Step)
    $mismatch = @{ Text = $null; Refusal = (New-WorkloadRefusal -Code 'workload_yaml_mismatch' -Key 'runner.workload_yaml_mismatch') }
    $text = $null
    try {
        $lines = ConvertTo-WorkloadStepText -Step $Step -Indent 0
        $text = (@($lines) -join "`n") + "`n"
    } catch {
        Write-Verbose "The authored step has no YAML form: $($_.Exception.Message)"
        return $mismatch
    }
    if ($text.Length -gt $script:WorkloadMaxStepChars) {
        return @{ Text = $null; Refusal = (New-WorkloadRefusal -Code 'workload_step_too_large' -Key 'runner.workload_step_too_large' -Arguments @{ maximum = $script:WorkloadMaxStepChars }) }
    }
    $parsed = $null
    try {
        Assert-LocalizationYamlCodec
        $parsed = ConvertFrom-Yaml -Yaml $text -Ordered
    } catch {
        Write-Verbose "The authored step does not parse as YAML: $($_.Exception.Message)"
        return $mismatch
    }
    $item = $null
    if ($parsed -is [System.Collections.IDictionary]) {
        $item = $parsed
    } elseif ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
        $items = @($parsed)
        if ($items.Count -eq 1) { $item = $items[0] }
    }
    if ($item -isnot [System.Collections.IDictionary] -or -not (Test-WorkloadYamlValueEqual -Expected $Step -Actual $item)) { return $mismatch }
    return @{ Text = $text; Refusal = $null }
}

function Write-WorkloadEngineLogLine {
    <#
    .SYNOPSIS
        Appends one filtered line to engine.log, within the size limit of a worker log.
    .DESCRIPTION
        A line that cannot be appended is counted in the call's Dropped and
        never throws, because a throw inside the stream consumer would stop
        the primitive that is running.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Level,
        [AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory)][hashtable]$Call
    )
    try {
        $state = $script:WorkloadEngineLogState[$Path]
        if ($null -eq $state) {
            $size = 0L
            if (Test-Path -LiteralPath $Path -PathType Leaf) { $size = [long](Get-Item -LiteralPath $Path).Length }
            $state = @{ Chars = $size; Full = ($size -ge $Call.Limit) }
            $script:WorkloadEngineLogState[$Path] = $state
        }
        if ($state.Full) { return }
        $time = ConvertTo-WorkloadUtcText -Instant ([DateTime]::UtcNow)
        $body = ([string]$Text) -replace "`r?`n", ' '
        $line = (Protect-SequenceSecretText -Text ('{0} {1} {2}' -f $time, $Level, $body)) + "`n"
        if ($state.Chars + $line.Length -gt $Call.Limit) {
            $line = "$time WARN engine.log limit reached`n"
            $state.Full = $true
        }
        [IO.File]::AppendAllText($Path, $line, [Text.UTF8Encoding]::new($false))
        $state.Chars += $line.Length
    } catch {
        $Call.Dropped = [int]$Call.Dropped + 1
    }
}

function Test-WorkloadCycleRestart {
    <#
    .SYNOPSIS
        Whether an exception, or one it wraps, is the engine's cooperative stop.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][Exception]$Exception)
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if (($current.Data -and $current.Data['YurunaCycleRestart']) -or ([string]$current.Message -like 'YurunaCycleRestart:*')) { return $true }
    }
    return $false
}

function Request-WorkloadEngineStop {
    <#
    .SYNOPSIS
        Creates the engine's stop flag when it does not exist, and owns it then.
    .DESCRIPTION
        The flag is opened with CreateNew: a flag another writer created is
        left as it is and is not owned, and it stops the engine all the same.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][hashtable]$Call)
    $flag = $null
    try {
        $flag = Join-Path (Initialize-YurunaRuntimeDir) 'control.cycle-restart'
        $stream = [IO.File]::Open($flag, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $Call.Owned = $true
        $Call.FlagPath = $flag
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes('workload-cancel')
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    } catch {
        Write-Verbose "The stop flag '$flag' was not created by this call: $($_.Exception.Message)"
    }
}

function Invoke-WorkloadEngineCall {
    <#
    .SYNOPSIS
        Runs engine code for the session; returns @{ Result; Canceled; Error }.
    .DESCRIPTION
        The only way this module calls the engine. Every record the script
        block writes is consumed as it is written: a [bool] is kept as the
        result (the last one wins), anything else becomes one filtered line
        of engine.log in the session folder. While the call has not asked for
        a stop, ShouldStop is asked at every record; on $true the stop flag of
        the runtime folder is created when it does not exist, and the engine
        stops at the gate before its next step. The flag is deleted afterwards
        only when this call created it. A cycle restart sets Canceled; any
        other exception is logged and returned, filtered, in Error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [scriptblock]$ShouldStop
    )
    $call = @{
        Result   = $null
        Canceled = $false
        Error    = $null
        Asked    = $false
        Owned    = $false
        FlagPath = $null
        Dropped  = 0
        Limit    = [long](Get-WorkloadProtocolLimit).MaxWorkerLogChars
    }
    $logPath = Join-Path ([string]$Session.Folder) 'engine.log'
    try {
        & $ScriptBlock *>&1 | ForEach-Object {
            $record = $_
            # A throw that left this consumer would stop the primitive that is running.
            try {
                if ($record -is [bool]) {
                    $call.Result = $record
                } else {
                    $level = 'OUT'
                    $text = $null
                    if ($record -is [System.Management.Automation.InformationRecord]) { $level = 'INFO'; $text = [string]$record.MessageData }
                    elseif ($record -is [System.Management.Automation.WarningRecord]) { $level = 'WARN'; $text = [string]$record.Message }
                    elseif ($record -is [System.Management.Automation.VerboseRecord]) { $level = 'VERBOSE'; $text = [string]$record.Message }
                    elseif ($record -is [System.Management.Automation.DebugRecord]) { $level = 'DEBUG'; $text = [string]$record.Message }
                    elseif ($record -is [System.Management.Automation.ErrorRecord]) { $level = 'ERROR'; $text = [string]$record }
                    else { $text = [string]$record }
                    Write-WorkloadEngineLogLine -Path $logPath -Level $level -Text $text -Call $call
                }
                if (-not $call.Asked -and $null -ne $ShouldStop) {
                    $stop = @(& $ShouldStop)
                    if ($stop.Count -gt 0 -and $stop[-1] -eq $true) {
                        $call.Asked = $true
                        Request-WorkloadEngineStop -Call $call
                    }
                }
            } catch {
                $call.Dropped = [int]$call.Dropped + 1
                Write-Verbose "A record of the engine was not handled: $($_.Exception.Message)"
            }
        }
    } catch {
        if (Test-WorkloadCycleRestart -Exception $_.Exception) {
            $call.Canceled = $true
        } else {
            $errorText = Protect-SequenceSecretText -Text ([string]$_.Exception.Message)
            Write-WorkloadEngineLogLine -Path $logPath -Level 'ERROR' -Text $errorText -Call $call
            $call.Error = $errorText
        }
    } finally {
        if ($call.Owned) {
            try {
                Remove-Item -LiteralPath $call.FlagPath -Force -ErrorAction Stop
            } catch {
                Write-Verbose "The stop flag '$($call.FlagPath)' this call created was not removed: $($_.Exception.Message)"
            }
        }
    }
    if ($call.Dropped -gt 0) { Write-Verbose "engine.log: $($call.Dropped) line(s) could not be written." }
    return @{ Result = $call.Result; Canceled = $call.Canceled; Error = $call.Error }
}

function Invoke-WorkloadStepList {
    <#
    .SYNOPSIS
        Runs the primitives of one operation through Invoke-Sequence itself.
    .DESCRIPTION
        One call with an in-memory definition, the session's variable table
        and -Continuation, so the console state lasts from one operation to
        the next and every per-step responsibility of the engine runs as a
        replay has it. Each operation runs under its own label, so two
        operations never share the identity a detached run derives its token
        from. The failure record is used only when it names this operation.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][object[]]$Steps,
        [Parameter(Mandatory)][int]$Seq,
        [scriptblock]$ShouldStop
    )
    $fail = Get-SequenceFailureState
    Reset-SequenceFailureSlot -Lifetime sequence -State $fail
    $fail.CurrentAction = $null
    $fail.CurrentStepNumber = 0
    $label = Join-Path ([string]$Session.Folder) ('op-{0:D4}.yml' -f $Seq)
    $definition = [ordered]@{
        description        = ('op-{0:D4}' -f $Seq)
        keystrokeMechanism = 'gui'
        steps              = [object[]]@($Steps)
    }
    $call = Invoke-WorkloadEngineCall -Session $Session -ShouldStop $ShouldStop -ScriptBlock ({
            Invoke-Sequence -HostType $Session.HostType -GuestKey $Session.GuestKey -VMName $Session.VMName -SequencePath $label `
                -Definition $definition -VariableScope $Session.Vars -Continuation
        }.GetNewClosure())
    $renamed = $false
    $finished = [string](Get-SequenceFinishedVMName)
    if ($finished -and -not [string]::Equals($finished, [string]$Session.VMName, [StringComparison]::Ordinal)) {
        $Session.VMName = $finished
        $renamed = $true
    }
    $record = $null
    $recordPath = Join-Path (Initialize-YurunaLogDir) 'last_failure.json'
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        try {
            $read = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($recordPath)) -AsHashtable -DateKind String
            if ($read -is [System.Collections.IDictionary] -and [string]$read['sequenceName'] -ceq ('op-{0:D4}' -f $Seq)) { $record = $read }
        } catch {
            Write-Verbose "The failure record '$recordPath' is not JSON: $($_.Exception.Message)"
        }
    }
    return @{
        Ok        = ($call.Result -eq $true -and -not $call.Canceled)
        Canceled  = [bool]$call.Canceled
        Completed   = [int]$fail.LastSucceededStepNumber
        Started     = [int]$fail.CurrentStepNumber
        Record      = $record
        Renamed     = $renamed
        Error       = $call.Error
        GuestChange = $fail.StepGuestChange
    }
}

function Get-WorkloadEffectState {
    <#
    .SYNOPSIS
        What an operation is known to have done to the guest: none-proven, applied or uncertain.
    .DESCRIPTION
        The first rule that holds wins: nothing started; a completed primitive
        that does more than observe, or whose handler recorded that it changed
        the guest; every primitive passed; the list stopped between
        primitives; the failing primitive recorded that it changed, or may
        have changed, the guest; the failing primitive only observes; a page
        step's account names its effect; its handler proved it changed
        nothing; it failed in its wait before any input.
        Every other case may have sent input and is uncertain.

        GuestChange is the engine's StepGuestChange slot: by step number,
        'applied' or 'uncertain' for a step of an 'observe' verb whose handler
        changed the guest anyway (sshWaitReady rotating or setting a password).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps,
        [Parameter(Mandatory)][int]$Completed,
        [Parameter(Mandatory)][int]$Started,
        [Parameter(Mandatory)][bool]$Ok,
        [AllowNull()][System.Collections.IDictionary]$Record,
        [AllowNull()][System.Collections.IDictionary]$GuestChange
    )
    # class(i) of step i, counted from 1; a step outside the list has no class.
    $class = [string[]]@(foreach ($step in $Steps) { Get-SequenceActionReplaySafety -Name ([string]$step['action']) })
    # What the handler of a step recorded doing to the guest, by step number.
    $changes = if ($null -ne $GuestChange) { $GuestChange } else { @{} }
    if ($Started -eq 0) { return 'none-proven' }
    for ($i = 1; $i -le $Completed; $i++) {
        if ($i -gt $class.Count -or $class[$i - 1] -cne 'observe') { return 'applied' }
        if ([string]$changes[[string]$i] -ceq 'applied') { return 'applied' }
    }
    if ($Ok) { return 'none-proven' }
    if ($Started -le $Completed) { return 'none-proven' }
    $failedChange = [string]$changes[[string]$Started]
    if ($failedChange -cin @('applied', 'uncertain')) { return $failedChange }
    if ($Started -le $class.Count -and $class[$Started - 1] -ceq 'observe') { return 'none-proven' }
    if ($null -ne $Record) {
        # A page step's own account knows whether its input was sent and answered,
        # which the record's stepEffect cannot say.
        $web = Get-WorkloadRecordField -Record $Record -Path @('context', 'causeDetail', 'web')
        if ($web -is [System.Collections.IDictionary]) { return [string]$web['effect'] }
        if ([string]$Record['stepEffect'] -ceq 'none-proven') { return 'none-proven' }
        $context = $Record['context']
        if ($context -is [System.Collections.IDictionary] -and [string]$context['stepFailurePhase'] -ceq 'wait') { return 'none-proven' }
    }
    return 'uncertain'
}

function Get-WorkloadRecordField {
    <#
    .SYNOPSIS
        A field of a failure record by its path of keys; $null when any part is missing.
    #>
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param([AllowNull()][System.Collections.IDictionary]$Record, [Parameter(Mandatory)][string[]]$Path)
    $current = $Record
    foreach ($key in $Path) {
        if ($current -isnot [System.Collections.IDictionary] -or -not $current.Contains($key)) { return $null }
        $current = $current[$key]
    }
    return , $current
}

function ConvertTo-WorkloadFailureView {
    <#
    .SYNOPSIS
        The filtered view of a failure record that a session shows.
    .DESCRIPTION
        Exactly the fields a client needs to judge a failure, filtered in the
        OCR-tolerant mode, and two evidence paths at most: the file the caller
        writes this view to and, while the session is not sensitive, the
        failure screenshot. The record's own file, the cycle transcript and
        the OCR text files are never named.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][hashtable]$Session
    )
    $view = [ordered]@{}
    foreach ($name in @('failureClass', 'severity', 'classificationSource', 'suggestedRecoveries', 'docUrl', 'reason', 'stepNumber',
            'totalSteps', 'actionVerb', 'action', 'description', 'stepEffect', 'stepEffectSource', 'innerActionVerb',
            'innerFailureClass', 'timestamp')) {
        $view[$name] = Get-WorkloadRecordField -Record $Record -Path @($name)
    }
    foreach ($name in @('stepFailurePhase', 'fromStep', 'matchedFailurePattern')) {
        $view[$name] = Get-WorkloadRecordField -Record $Record -Path @('context', $name)
    }
    foreach ($name in @('ocrTail', 'patternsSought', 'closestOnScreen', 'freshWindowNearMiss', 'consoleFlood', 'consoleStaticSeconds',
            'blankScreenSeconds', 'hostInputFault', 'web', 'loginEcho', 'pauseBeforeStepSeconds')) {
        $view[$name] = Get-WorkloadRecordField -Record $Record -Path @('context', 'causeDetail', $name)
    }
    $filtered = Protect-SequenceSecretObject -InputObject $view -OcrTolerant
    $vmName = [string]$Record['vmName']
    if (-not $vmName) { $vmName = [string]$Session.VMName }
    $screenshot = Join-Path (Initialize-YurunaLogDir) "failure_screenshot_$vmName.png"
    $filtered['evidence'] = [ordered]@{
        view       = (Join-Path ([string]$Session.Folder) ('failure-{0:D4}.json' -f [int]$Session.OperationSeq))
        screenshot = $(if ((Test-Path -LiteralPath $screenshot -PathType Leaf) -and -not [bool]$Session.SensitiveState) { $screenshot } else { $null })
    }
    return $filtered
}

function Get-WorkloadLastFailure {
    <#
    .SYNOPSIS
        The filtered view of the session's last failure, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Session)
    return $Session.LastFailure
}

function Add-WorkloadJournalEntry {
    <#
    .SYNOPSIS
        Appends one operation to the journal and its file; returns whether it was added.
    .DESCRIPTION
        An operation id already in the journal is not added again. The file
        journal.ndjson gets one filtered line per entry. A line that cannot be
        written keeps the entry in memory and adds the warning
        workload_journal_write_failed to the list given as -Warning.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry,
        [AllowNull()][System.Collections.IList]$Warning
    )
    $operationId = [string]$Entry['operationId']
    foreach ($existing in $Session.Journal) {
        if ([string]$existing['operationId'] -ceq $operationId) { return $false }
    }
    $Session.Journal.Add($Entry)
    try {
        $line = ConvertTo-Json -InputObject (Protect-SequenceSecretObject -InputObject $Entry) -Compress -Depth 8
        [IO.File]::AppendAllText((Join-Path ([string]$Session.Folder) 'journal.ndjson'), $line + "`n", [Text.UTF8Encoding]::new($false))
    } catch {
        $detail = Protect-SequenceSecretText -Text ([string]$_.Exception.Message)
        Write-Verbose "The journal line of '$operationId' was not written: $detail"
        if ($null -ne $Warning) {
            $null = $Warning.Add([ordered]@{
                    code    = 'workload_journal_write_failed'
                    message = (Format-YurunaOperatorMessage -Key 'runner.workload_journal_write_failed' -Arguments @{ detail = $detail })
                })
        }
    }
    return $true
}

function Get-WorkloadJournalEntry {
    <#
    .SYNOPSIS
        The journal entries in order; with -RunnableOnly only the steps and actions that passed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [switch]$RunnableOnly
    )
    foreach ($entry in @($Session.Journal)) {
        if (-not $RunnableOnly -or $entry['runnable'] -eq $true) { $entry }
    }
}

function Get-WorkloadJournalResult {
    <#
    .SYNOPSIS
        The result workload_journal serves: the runnable steps as YAML, every entry, and the state changes.
    .DESCRIPTION
        stateChanges are the entries that are not runnable and whose effect
        is applied or uncertain: a failed login can still have typed the user
        name, and a replay changed the guest in ways the steps do not carry.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary], [object[]])]
    param([Parameter(Mandatory)][hashtable]$Session)
    $entries = @(Get-WorkloadJournalEntry -Session $Session)
    $runnable = @($entries | Where-Object { $_['runnable'] -eq $true })
    $summary = [object[]]@(foreach ($entry in $entries) {
            [ordered]@{
                seq                 = $entry['seq']
                operationId         = $entry['operationId']
                tool                = $entry['tool']
                outcome             = $entry['outcome']
                effect              = $entry['effect']
                completedPrimitives = $entry['completedPrimitives']
                failedPrimitive     = $entry['failedPrimitive']
                failureClass        = $entry['failureClass']
            }
        })
    $changes = [object[]]@(foreach ($entry in $entries) {
            if ($entry['runnable'] -ne $true -and [string]$entry['effect'] -cin @('applied', 'uncertain')) {
                $authored = $entry['authored']
                [ordered]@{
                    seq      = $entry['seq']
                    tool     = $entry['tool']
                    outcome  = $entry['outcome']
                    effect   = $entry['effect']
                    sequence = $(if ([string]$entry['tool'] -ceq 'workload_run_sequence' -and $authored -is [System.Collections.IDictionary]) { [string]$authored['sequence'] } else { '' })
                }
            }
        })
    $result = [ordered]@{
        ok           = $true
        steps        = $runnable.Count
        yaml         = (@($runnable | ForEach-Object { [string]$_['yaml'] }) -join '')
        entries      = $summary
        stateChanges = $changes
    }
    return , (Protect-SequenceSecretObject -InputObject $result)
}

function Get-WorkloadFailureResult {
    <#
    .SYNOPSIS
        The result workload_failure serves: the filtered view of the last failure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Session)
    return [ordered]@{ ok = $true; failure = $Session.LastFailure }
}

function Enter-WorkloadSensitiveState {
    <#
    .SYNOPSIS
        Marks the session as having had secret input; it stays so until the session ends.
    .DESCRIPTION
        Text can be filtered, pixels cannot: from now on no result names or
        carries a frame or a screenshot.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][int]$Seq
    )
    if (-not [bool]$Session.SensitiveState) { $Session.SensitiveSinceSeq = $Seq }
    $Session.SensitiveState = $true
}

function Test-WorkloadSensitiveState {
    <#
    .SYNOPSIS
        Whether the session has had secret input.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Session)
    return [bool]$Session.SensitiveState
}

function Protect-WorkloadReply {
    <#
    .SYNOPSIS
        A result with every string filtered for the values the session registered.
    .DESCRIPTION
        The worker shell frames the answer, filters the framed line as text
        and checks it before it writes it to the pipe.
    #>
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param([AllowNull()]$InputObject)
    return , (Protect-SequenceSecretObject -InputObject $InputObject)
}

function Get-WorkloadSessionPhraseLibrary {
    <#
    .SYNOPSIS
        The phrase libraries in force: the source sequence's, else the framework's.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][hashtable]$Session)
    if ($null -ne $Session -and [string]$Session.SourceSequencePath) {
        return (Get-SequencePhraseLibrary -SequencePath ([string]$Session.SourceSequencePath))
    }
    return (Get-SequencePhraseLibrary)
}

function Invoke-WorkloadOperation {
    <#
    .SYNOPSIS
        Runs one workload_step or workload_action: checks, dispatch, snapshot, journal and result.
    .DESCRIPTION
        An operation id that has a result is answered from it and runs
        nothing. Every check runs before anything is sent to the guest, and a
        refused operation consumes no sequence number and is not journaled.
        A dispatched operation is journaled on every way out, also when it
        throws, so the journal holds every operation that may have sent input.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][ValidateSet('workload_step', 'workload_action')][string]$Tool,
        [Parameter(Mandatory)][hashtable]$Call
    )
    $request = $Call.Params
    if ($request -isnot [System.Collections.IDictionary]) { $request = @{} }
    $operationId = [string]$request['operationId']
    if ($Session.Results.ContainsKey($operationId)) { return $Session.Results[$operationId] }

    $refusal = Get-WorkloadSessionRefusal -Session $Session -Tool $Tool -NeedsVm -NeedsOwnership
    if ($null -ne $refusal) { return (ConvertTo-WorkloadOperationRefusal -Refusal $refusal) }
    $intent = [string]$request['intent']
    $refusal = Test-WorkloadIntent -Intent $intent
    if ($null -ne $refusal) { return (ConvertTo-WorkloadOperationRefusal -Refusal $refusal) }

    $warnings = [Collections.Generic.List[object]]::new()
    $clientText = [Collections.Generic.List[string]]::new()
    $isStep = $Tool -ceq 'workload_step'
    $surface = 'screen'
    $primitives = @()
    if ($isStep) {
        $sentence = [string]$request['step']
        if ($request.Contains('on') -and -not [string]::IsNullOrEmpty([string]$request['on'])) { $surface = [string]$request['on'] }
        $timeoutGiven = $request.Contains('timeoutSeconds') -and $null -ne $request['timeoutSeconds']
        $timeout = if ($timeoutGiven) { [int]$request['timeoutSeconds'] } else { 0 }
        $library = Get-WorkloadSessionPhraseLibrary -Session $Session
        $Session.PhraseLibrary = $library
        try {
            $primitives = @(Resolve-StepPhrase -Sentence $sentence -Surface $surface -Library $library -TimeoutSeconds $timeout `
                    -Description $intent -Location 'workload_step')
        } catch {
            $message = [string]$_.Exception.Message
            if (-not $message.StartsWith('PlannerFatal: ', [StringComparison]::Ordinal)) { throw }
            $refusal = New-WorkloadRefusal -Code 'workload_step_unresolved' -Key 'runner.workload_step_unresolved' -Arguments @{ detail = $message.Substring('PlannerFatal: '.Length) }
            return (ConvertTo-WorkloadOperationRefusal -Refusal $refusal)
        }
        $authored = [ordered]@{ step = $sentence; on = $surface }
        if ($timeoutGiven) { $authored['timeoutSeconds'] = $timeout }
        $authored['description'] = $intent
        $clientText.Add($sentence)
    } else {
        $action = [string]$request['action']
        $fields = $request['fields']
        if ($fields -isnot [System.Collections.IDictionary]) { $fields = [ordered]@{} }
        $refusal = Test-WorkloadVerb -Action $action
        if ($null -ne $refusal) { return (ConvertTo-WorkloadOperationRefusal -Refusal $refusal) }
        $check = Test-WorkloadActionField -Action $action -Fields $fields
        if ($null -ne $check.Refusal) { return (ConvertTo-WorkloadOperationRefusal -Refusal $check.Refusal) }
        foreach ($warning in $check.Warnings) { $warnings.Add($warning) }
        $authored = [ordered]@{ action = $action }
        foreach ($key in @($fields.Keys)) { $authored[[string]$key] = $fields[$key] }
        $authored['description'] = $intent
        $primitive = [ordered]@{}
        foreach ($key in @($authored.Keys)) { $primitive[$key] = $authored[$key] }
        $primitives = @($primitive)
        $clientText.Add($action)
        foreach ($text in @(Get-WorkloadStringValue -Value $fields)) { $clientText.Add($text) }
    }
    $clientText.Add($intent)

    foreach ($primitive in $primitives) {
        $refusal = Test-WorkloadVerb -Action ([string]$primitive['action'])
        if ($null -ne $refusal) { return (ConvertTo-WorkloadOperationRefusal -Refusal $refusal) }
    }
    $secret = Test-WorkloadSecretInput -Session $Session -Tool $Tool -Steps $primitives -ClientText $clientText.ToArray()
    if ($null -ne $secret.Refusal) { return (ConvertTo-WorkloadOperationRefusal -Refusal $secret.Refusal) }
    $yaml = ConvertTo-WorkloadStepYaml -Step $authored
    if ($null -ne $yaml.Refusal) { return (ConvertTo-WorkloadOperationRefusal -Refusal $yaml.Refusal) }

    $maskBefore = Get-WorkloadMaskFailedCount
    foreach ($name in $secret.SecretVariable) {
        $null = Register-SequenceSecret -Value ([string]$Session.Vars[$name]) -Source "variable:$name"
    }
    if ((Get-WorkloadMaskFailedCount) -gt $maskBefore) {
        return (ConvertTo-WorkloadOperationRefusal -Refusal (New-WorkloadRefusal -Code 'workload_mask_failed' -Key 'runner.workload_mask_failed'))
    }

    $Session.OperationSeq = [int]$Session.OperationSeq + 1
    $seq = [int]$Session.OperationSeq
    if ($secret.SecretInput) { Enter-WorkloadSensitiveState -Session $Session -Seq $seq }
    $total = $primitives.Count
    $progressLabel = if ($isStep) { [string]$primitives[0]['fromStep'] } else { [string]$authored['action'] }
    $primitiveList = [object[]]@(for ($i = 0; $i -lt $total; $i++) {
            $actionName = [string]$primitives[$i]['action']
            [ordered]@{
                index       = $i + 1
                action      = $actionName
                replayClass = (Get-SequenceActionReplaySafety -Name $actionName)
                sensitive   = ($primitives[$i]['sensitive'] -eq $true)
            }
        })
    $resultSurface = if ($isStep) { $surface } else { 'screen' }
    # A page operation is a page sentence or a page verb; its result describes the page.
    $isPage = if ($isStep) { $surface -ceq 'page' } else { ([string]$authored['action']).StartsWith('web', [StringComparison]::Ordinal) }
    $pageBefore = $null
    if ($isPage) {
        $openPage = Get-WorkloadOpenPage -Session $Session
        if ($null -ne $openPage) { $pageBefore = @{ Url = [string]$openPage['Cdp'].Page.Url; Generation = [int]$openPage['Cdp'].Page.Generation } }
    }
    $startedAt = [DateTime]::UtcNow
    $vmBefore = [string]$Session.VMName
    $maskBefore = Get-WorkloadMaskFailedCount
    if ($null -ne $Call.Progress) { $null = & $Call.Progress 0 $total $progressLabel }

    $list = $null
    try {
        $list = Invoke-WorkloadStepList -Session $Session -Steps $primitives -Seq $seq -ShouldStop $Call.ShouldStop
        $effect = Get-WorkloadEffectState -Steps $primitives -Completed $list.Completed -Started $list.Started -Ok $list.Ok -Record $list.Record `
            -GuestChange $list.GuestChange
        $outcome = if ($list.Ok) { 'passed' } elseif ($list.Canceled) { 'canceled' } else { 'failed' }
        $state = switch ($outcome) { 'passed' { 'succeeded' } 'canceled' { 'canceled' } default { 'failed' } }
        $failedPrimitive = if ($outcome -ceq 'failed' -and $list.Started -gt $list.Completed) { [int]$list.Started } else { 0 }
        $view = $null
        if ($outcome -ceq 'failed' -and $null -ne $list.Record) {
            $view = ConvertTo-WorkloadFailureView -Record $list.Record -Session $Session
            [IO.File]::WriteAllText([string]$view['evidence']['view'], (ConvertTo-Json -InputObject $view -Depth 12), [Text.UTF8Encoding]::new($false))
            $Session.LastFailure = $view
        }

        $snapshot = $null
        $snapshotError = $null
        $captured = $null
        try {
            $captured = if ($isPage) { Save-WorkloadPageSnapshot -Worker $Call.Worker } else { Save-WorkloadScreenSnapshot -Worker $Call.Worker }
            if ($captured -is [System.Collections.IDictionary] -and $captured['ok'] -eq $true) {
                $snapshot = $captured['file']
            } elseif ($captured -is [System.Collections.IDictionary] -and $captured['error'] -is [System.Collections.IDictionary]) {
                $snapshotError = [string]$captured['error']['code']
            } else {
                $snapshotError = 'workload_capture_failed'
            }
        } catch {
            Write-Verbose "The snapshot after operation $seq was not taken: $($_.Exception.Message)"
            $snapshotError = 'workload_capture_failed'
        }
        if ((Get-WorkloadMaskFailedCount) -gt $maskBefore) {
            $warnings.Add([ordered]@{
                    code    = 'workload_mask_unconfirmed'
                    message = (Format-YurunaOperatorMessage -Key 'runner.workload_mask_unconfirmed')
                })
        }
        $failureClass = ''
        if ($outcome -ceq 'failed') { $failureClass = if ($null -ne $list.Record) { [string]$list.Record['failureClass'] } else { 'unknown' } }
        $endedAt = [DateTime]::UtcNow
        $entry = [ordered]@{
            schema              = 'yuruna.workload-journal/v1'
            seq                 = $seq
            operationId         = $operationId
            tool                = $Tool
            outcome             = $outcome
            runnable            = ($outcome -ceq 'passed')
            surface             = $resultSurface
            authored            = $authored
            yaml                = $yaml.Text
            primitives          = $primitiveList
            completedPrimitives = [int]$list.Completed
            failedPrimitive     = $failedPrimitive
            effect              = $effect
            failureClass        = $failureClass
            secretInput         = [bool]$secret.SecretInput
            vmName              = $vmBefore
            vmNameAfter         = [string]$Session.VMName
            startedAtUtc        = (ConvertTo-WorkloadUtcText -Instant $startedAt)
            endedAtUtc          = (ConvertTo-WorkloadUtcText -Instant $endedAt)
        }
        $journaled = Add-WorkloadJournalEntry -Session $Session -Entry $entry -Warning $warnings

        $result = [ordered]@{
            ok          = ($outcome -ceq 'passed')
            state       = $state
            outcome     = $outcome
            dispatched  = $true
            operationId = $operationId
            seq         = $seq
            tool        = $Tool
            ran         = $yaml.Text
            surface     = $(if ($isPage) { 'page' } else { $resultSurface })
            snapshot    = $snapshot
        }
        if ($null -ne $snapshotError) { $result['snapshotError'] = $snapshotError }
        $events = [Collections.Generic.List[string]]::new()
        if ($isPage) {
            $result['page'] = $null
            if ($null -ne $snapshot) { $result['page'] = [ordered]@{ url = [string]$captured['url']; title = [string]$captured['title'] } }
            $openPage = Get-WorkloadOpenPage -Session $Session
            if ($null -ne $openPage) {
                $urlAfter = [string]$openPage['Cdp'].Page.Url
                if ($null -eq $pageBefore -or $urlAfter -cne $pageBefore.Url -or [int]$openPage['Cdp'].Page.Generation -ne $pageBefore.Generation) {
                    $parsed = $null
                    $navigated = $urlAfter
                    if ([uri]::TryCreate($urlAfter, [UriKind]::Absolute, [ref]$parsed) -and $parsed.Scheme -in @('http', 'https')) { $navigated = $parsed.PathAndQuery }
                    $events.Add("navigated to $navigated")
                }
            }
        }
        $result['events'] = [object[]]$events.ToArray()
        $result['progress'] = [ordered]@{ completed = [int]$list.Completed; total = $total; failedAt = $failedPrimitive }
        $result['primitives'] = $primitiveList
        $result['effect'] = $effect
        $result['journaled'] = [bool]$journaled
        $result['secretInput'] = [bool]$secret.SecretInput
        $result['sensitiveState'] = [bool]$Session.SensitiveState
        $result['vmName'] = [string]$Session.VMName
        $result['renamed'] = [bool]$list.Renamed
        $result['warnings'] = [object[]]$warnings.ToArray()
        $result['startedAtUtc'] = ConvertTo-WorkloadUtcText -Instant $startedAt
        $result['endedAtUtc'] = ConvertTo-WorkloadUtcText -Instant $endedAt
        if ($outcome -ceq 'failed') {
            $index = $failedPrimitive
            if ($index -eq 0) { $index = [Math]::Min([int]$list.Completed + 1, $total) }
            $label = if ($null -ne $list.Record) { Protect-SequenceSecretText -Text ([string]$list.Record['action']) } else { Protect-SequenceSecretText -Text ([string]$list.Error) }
            $result['error'] = [ordered]@{
                code    = 'workload_step_failed'
                class   = $(if ($null -ne $list.Record) { [string]$list.Record['failureClass'] } else { 'unknown' })
                message = (Format-YurunaOperatorMessage -Key 'runner.workload_step_failed' -Arguments @{
                        index = $index; total = $total; action = [string]$primitives[$index - 1]['action']; label = $label })
                failure = $(if ($null -ne $view) { [string]$view['evidence']['view'] } else { $null })
            }
        } elseif ($outcome -ceq 'canceled') {
            $result['error'] = [ordered]@{
                code    = 'workload_operation_canceled'
                class   = $null
                message = (Format-YurunaOperatorMessage -Key 'runner.workload_operation_canceled' -Arguments @{ completed = [int]$list.Completed; total = $total })
                failure = $null
            }
        }
        $protected = Protect-WorkloadReply -InputObject $result
        $Session.Results[$operationId] = $protected
        return $protected
    } catch {
        $alreadyJournaled = @($Session.Journal | Where-Object { [string]$_['operationId'] -ceq $operationId }).Count -gt 0
        if (-not $alreadyJournaled) {
            try {
                $null = Add-WorkloadJournalEntry -Session $Session -Entry ([ordered]@{
                        schema              = 'yuruna.workload-journal/v1'
                        seq                 = $seq
                        operationId         = $operationId
                        tool                = $Tool
                        outcome             = 'failed'
                        runnable            = $false
                        surface             = $resultSurface
                        authored            = $authored
                        yaml                = $yaml.Text
                        primitives          = $primitiveList
                        completedPrimitives = $(if ($null -ne $list) { [int]$list.Completed } else { 0 })
                        failedPrimitive     = 0
                        effect              = 'uncertain'
                        failureClass        = 'unknown'
                        secretInput         = [bool]$secret.SecretInput
                        vmName              = $vmBefore
                        vmNameAfter         = [string]$Session.VMName
                        startedAtUtc        = (ConvertTo-WorkloadUtcText -Instant $startedAt)
                        endedAtUtc          = (ConvertTo-WorkloadUtcText -Instant ([DateTime]::UtcNow))
                    })
            } catch {
                Write-Verbose "Operation $seq was not journaled after it threw: $($_.Exception.Message)"
            }
        }
        throw
    }
}

function Invoke-WorkloadStepRequest {
    <#
    .SYNOPSIS
        The step.run handler: runs one sentence.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    if ($null -eq $Call.Worker.Session) { return (New-WorkloadRefusal -Code 'workload_no_session' -Key 'runner.workload_no_session') }
    return (Invoke-WorkloadOperation -Session $Call.Worker.Session -Tool 'workload_step' -Call $Call)
}

function Invoke-WorkloadActionRequest {
    <#
    .SYNOPSIS
        The action.run handler: runs one registered verb.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    if ($null -eq $Call.Worker.Session) { return (New-WorkloadRefusal -Code 'workload_no_session' -Key 'runner.workload_no_session') }
    return (Invoke-WorkloadOperation -Session $Call.Worker.Session -Tool 'workload_action' -Call $Call)
}

function Invoke-WorkloadPhraseRequest {
    <#
    .SYNOPSIS
        The phrases.list handler: the sentences in force, with their slots and surfaces.
    .DESCRIPTION
        Answers before a session exists, from the framework library. The
        reader is loaded on demand from the resolver module, which loads no
        engine module.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    if (-not (Get-Command Get-SequencePhraseLibrary -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Test.SequenceResolve.psm1') -Global -DisableNameChecking
    }
    $library = Get-WorkloadSessionPhraseLibrary -Session $Call.Worker.Session
    $search = ''
    if ($Call.Params -is [System.Collections.IDictionary]) { $search = [string]$Call.Params['search'] }
    $matched = [Collections.Generic.List[object]]::new()
    foreach ($phrase in @($library.Phrases)) {
        if ([string]::IsNullOrEmpty($search) -or
            ([string]$phrase.Id).Contains($search, [StringComparison]::OrdinalIgnoreCase) -or
            ([string]$phrase.Sentence).Contains($search, [StringComparison]::OrdinalIgnoreCase)) { $matched.Add($phrase) }
    }
    $sorted = $matched.ToArray()
    [Array]::Sort($sorted, [Comparison[object]] { param($left, $right) [string]::CompareOrdinal([string]$left.Id, [string]$right.Id) })
    $limit = [int](Get-WorkloadProtocolLimit).MaxPhraseEntries
    $phrases = [object[]]@(foreach ($phrase in @($sorted | Select-Object -First $limit)) {
            [ordered]@{
                id       = [string]$phrase.Id
                sentence = [string]$phrase.Sentence
                surfaces = [object[]]@($phrase.Surfaces.Keys | ForEach-Object { [string]$_ })
                slots    = [object[]]@(foreach ($slotName in @($phrase.Slots.Keys)) { [ordered]@{ name = [string]$slotName; type = [string]$phrase.Slots[$slotName] } })
                tier     = [string]$phrase.Tier
            }
        })
    return [ordered]@{
        ok        = $true
        phrases   = $phrases
        total     = $sorted.Count
        truncated = ($sorted.Count -gt $phrases.Count)
    }
}

function Save-WorkloadScreenSnapshot {
    <#
    .SYNOPSIS
        Takes a screen snapshot: the frame, its word boxes as entries with references, and its file.
    .DESCRIPTION
        The one producer of screen snapshots. The reference table of the
        earlier snapshot is dropped first, so a failed capture leaves no old
        reference usable. Every text read from the frame passes the secret
        filter in its OCR-tolerant mode. The raw frame stays in the cycle's
        screen folder and never enters the session folder; its path is
        returned only when asked and while the session is not sensitive.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Worker,
        [AllowEmptyString()][AllowNull()][string]$Find,
        [switch]$WithImage
    )
    $Worker.Screen.Table = $null
    $Worker.Screen.Boxes = @()
    $session = $Worker.Session
    $vmName = [string]$session.VMName
    $path = $null
    try {
        $dir = Get-CycleScreenDir -VMName $vmName -WhatIf:$false
        if (-not [string]::IsNullOrEmpty([string]$dir)) {
            $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmssfff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            $frame = Get-VMScreenshot -VMName $vmName -OutFile (Join-Path ([string]$dir) ('raw_' + $stamp + '.png'))
            if ($null -ne $frame -and $frame -isnot [bool] -and -not [string]::IsNullOrEmpty([string]$frame) -and
                (Test-Path -LiteralPath ([string]$frame) -PathType Leaf)) { $path = [string]$frame }
        }
    } catch {
        Write-Verbose "The screen of '$vmName' was not captured: $($_.Exception.Message)"
        $path = $null
    }
    if ($null -eq $path) { return (New-WorkloadRefusal -Code 'workload_capture_failed' -Key 'runner.workload_capture_failed') }

    $rawBoxes = @()
    try {
        $rawBoxes = @(Get-TesseractWordBox -ImagePath $path | ForEach-Object { $_ })
    } catch {
        Write-Verbose "No word boxes were read from '$path': $($_.Exception.Message)"
        $rawBoxes = @()
    }
    $lines = @()
    if ($rawBoxes.Count -gt 0) { $lines = Get-OcrWordBoxLine -Box $rawBoxes }
    $other = [ordered]@{}
    foreach ($name in @(Get-EnabledOcrProvider)) {
        if ([string]$name -eq 'tesseract') { continue }
        try {
            $other[[string]$name] = Protect-SequenceSecretText -Text ([string](Invoke-OcrProvider -Name $name -ImagePath $path)) -OcrTolerant
        } catch {
            Write-Verbose "The OCR provider '$name' read nothing from '$path': $($_.Exception.Message)"
        }
    }
    $boxes = [object[]]@(foreach ($box in $rawBoxes) {
            if ($null -eq $box) { continue }
            $copy = @{}
            if ($box -is [System.Collections.IDictionary]) {
                foreach ($key in @($box.Keys)) { $copy[$key] = $box[$key] }
            } else {
                foreach ($property in $box.PSObject.Properties) { $copy[$property.Name] = $property.Value }
            }
            $copy['text'] = Protect-SequenceSecretText -Text ([string]$copy['text']) -OcrTolerant
            $copy
        })
    foreach ($segment in @($lines)) {
        if ($segment -is [System.Collections.IDictionary]) { $segment['text'] = Protect-SequenceSecretText -Text ([string]$segment['text']) -OcrTolerant }
    }

    $ordinal = [int]$Worker.Screen.Ordinal + 1
    $Worker.Screen.Ordinal = $ordinal
    $leaf = Split-Path -Leaf $path
    $snap = ConvertTo-WorkloadScreenSnapshot -Line $lines -OtherText $other -VmName $vmName -FrameName $leaf -Ordinal $ordinal `
        -ReferenceBase ([long]$Worker.Screen.Counter) -Find $Find
    $file = Join-Path ([string]$session.Folder) ('screen-{0:D4}.txt' -f $ordinal)
    [IO.File]::WriteAllText($file, $snap.FileText, [Text.UTF8Encoding]::new($false))
    $Worker.Screen.Table = $snap.Table
    $Worker.Screen.Boxes = $boxes
    $Worker.Screen.Counter = $snap.ReferenceBase

    $result = [ordered]@{
        ok        = $true
        surface   = 'screen'
        snapshot  = $ordinal
        file      = $file
        frame     = $leaf
        text      = $snap.InlineText
        entries   = $snap.Entries
        shown     = $snap.Shown
        truncated = $snap.Truncated
    }
    if ($WithImage -and $leaf.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-WorkloadSensitiveState -Session $session) { $result['imageWithheld'] = $true } else { $result['imagePath'] = $path }
    }
    return $result
}

function Get-WorkloadOpenPage {
    <#
    .SYNOPSIS
        The web session of the session's VM while its page is open, else $null.
    .DESCRIPTION
        The web session module is loaded by the first page verb, so before that
        its commands do not exist and no page can be open.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][hashtable]$Session)
    if ($null -eq $Session -or [string]::IsNullOrEmpty([string]$Session.VMName)) { return $null }
    if (-not (Get-Command Get-GuestWebSession -ErrorAction SilentlyContinue)) { return $null }
    $entry = Get-GuestWebSession -VMName ([string]$Session.VMName)
    if ($null -eq $entry -or -not (Test-WebCdpOpen -Connection $entry['Cdp'])) { return $null }
    return $entry
}

function Read-WorkloadPageForest {
    <#
    .SYNOPSIS
        The forest of an open page, or a capture refusal when the page could not be read.
    .DESCRIPTION
        A page failure (a dialog, a crashed page, a lost socket) is a capture
        refusal; any other exception leaves the function.
    .OUTPUTS
        System.Collections.Hashtable: Forest, Refusal.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$PageEntry)
    try {
        return @{ Forest = (Read-WebPageForest -Connection $PageEntry['Cdp'] -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(30))); Refusal = $null }
    } catch {
        if ($null -eq (Get-WebFailureData -ErrorRecord $_)) { throw }
        Write-Verbose "The page was not read: $($_.Exception.Message)"
        return @{ Forest = $null; Refusal = (New-WorkloadRefusal -Code 'workload_capture_failed' -Key 'runner.workload_capture_failed') }
    }
}

function Save-WorkloadPageSnapshot {
    <#
    .SYNOPSIS
        Takes a page snapshot: the page's elements as entries with references, and its file.
    .DESCRIPTION
        The one producer of page snapshots. The reference table of the earlier
        snapshot is dropped first, so a failed capture leaves no old reference
        usable. Every name, tag value, the title and the URL pass the secret
        filter before the text is built, so the file in the session folder
        holds filtered text only. Page text is exact, so the filter does not
        run in its OCR-tolerant mode.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Worker,
        [AllowEmptyString()][AllowNull()][string]$Find
    )
    $Worker.Page.Table = $null
    $pageEntry = Get-WorkloadOpenPage -Session $Worker.Session
    if ($null -eq $pageEntry) { return (New-WorkloadRefusal -Code 'workload_no_page' -Key 'runner.workload_no_page') }
    $read = Read-WorkloadPageForest -PageEntry $pageEntry
    if ($null -ne $read.Refusal) { return $read.Refusal }
    $forest = $read.Forest

    $entries = [object[]](Get-WebPageSnapshotEntry -Forest $forest)
    foreach ($item in $entries) {
        $item.Name = Protect-SequenceSecretText -Text ([string]$item.Name)
        $item.Tags = [string[]]@(foreach ($tag in @($item.Tags)) {
                $at = ([string]$tag).IndexOf('=')
                if ($at -lt 0) { Protect-SequenceSecretText -Text ([string]$tag) }
                else { ([string]$tag).Substring(0, $at + 1) + (Protect-SequenceSecretText -Text ([string]$tag).Substring($at + 1)) }
            })
    }
    $url = Protect-SequenceSecretText -Text ([string]$forest.Url)
    $title = Protect-SequenceSecretText -Text ([string]$forest.Title)

    $Worker.Page.Ordinal = [int]$Worker.Page.Ordinal + 1
    $ordinal = [int]$Worker.Page.Ordinal
    $snap = ConvertTo-WorkloadPageSnapshot -Entry $entries -Url $url -Title $title -Generation ([int]$forest.Generation) -Ordinal $ordinal `
        -ReferenceBase ([long]$Worker.Page.Counter) -Find $Find
    $file = Join-Path ([string]$Worker.Session.Folder) ('page-{0:D4}.txt' -f $ordinal)
    [IO.File]::WriteAllText($file, $snap.FileText, [Text.UTF8Encoding]::new($false))
    $Worker.Page.Table = $snap.Table
    $Worker.Page.Counter = $snap.ReferenceBase

    return [ordered]@{
        ok        = $true
        surface   = 'page'
        snapshot  = $ordinal
        file      = $file
        url       = $url
        title     = $title
        text      = $snap.InlineText
        entries   = $snap.Entries
        shown     = $snap.Shown
        truncated = $snap.Truncated
    }
}

function Invoke-WorkloadSnapshotRequest {
    <#
    .SYNOPSIS
        The snapshot.take handler: a snapshot of the screen or of the page.
    .DESCRIPTION
        The image argument has no meaning on the page surface and is ignored there.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    if ($null -eq $Call.Worker.Session) { return (New-WorkloadRefusal -Code 'workload_no_session' -Key 'runner.workload_no_session') }
    $refusal = Get-WorkloadSessionRefusal -Session $Call.Worker.Session -Tool 'workload_snapshot' -NeedsVm -NeedsOwnership
    if ($null -ne $refusal) { return $refusal }
    $params = if ($Call.Params -is [System.Collections.IDictionary]) { $Call.Params } else { @{} }
    if ([string]$params['surface'] -ceq 'page') { return (Save-WorkloadPageSnapshot -Worker $Call.Worker -Find ([string]$params['find'])) }
    # The front end forwards only the surfaces the worker's hello lists.
    if ([string]$params['surface'] -cne 'screen') { throw [System.ArgumentOutOfRangeException]::new('surface') }
    return (Save-WorkloadScreenSnapshot -Worker $Call.Worker -Find ([string]$params['find']) -WithImage:($params['image'] -eq $true))
}

function Get-WorkloadPageSuggestion {
    <#
    .SYNOPSIS
        The sentences, or the page primitive with nth, that target one element of the current page snapshot.
    .DESCRIPTION
        A reference is stale once the page navigated since its snapshot or its
        element is no longer the one the locator finds. Uniqueness is judged by
        the locator the page verbs use, over a fresh read of the whole page.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Call,
        [Parameter(Mandatory)][string]$Reference
    )
    $stale = New-WorkloadRefusal -Code 'workload_stale_reference' -Key 'runner.workload_stale_reference' -Arguments @{ reference = $Reference }
    $target = $Call.Worker.Page.Table[$Reference]
    $pageEntry = Get-WorkloadOpenPage -Session $Call.Worker.Session
    if ($null -eq $pageEntry) { return (New-WorkloadRefusal -Code 'workload_no_page' -Key 'runner.workload_no_page') }
    if ([int]$target.Generation -ne [int]$pageEntry['Cdp'].Page.Generation) { return $stale }
    $read = Read-WorkloadPageForest -PageEntry $pageEntry
    if ($null -ne $read.Refusal) { return $read.Refusal }
    $role = [string]$target.Role
    $name = [string]$target.Name
    $hits = [object[]](Find-WebElement -Forest $read.Forest -Role $role -Name $name)
    $position = 0
    for ($i = 0; $i -lt $hits.Count; $i++) {
        $address = $hits[$i].Address
        if ([string]$address.SessionId -ceq [string]$target.Address.SessionId -and [int]$address.BackendNodeId -eq [int]$target.Address.BackendNodeId) {
            $position = $i + 1
            break
        }
    }
    if ($position -eq 0) { return $stale }

    $suggestions = [Collections.Generic.List[object]]::new()
    if ($hits.Count -eq 1) {
        $library = Get-WorkloadSessionPhraseLibrary -Session $Call.Worker.Session
        $byId = @{}
        foreach ($phrase in @($library.Phrases)) { $byId[[string]$phrase.Id] = $phrase }
        $candidates = @(switch -CaseSensitive ($role) {
            'button' { @(@{ Id = 'click-button'; Value = @{ label = $name } }) }
            'link' { @(@{ Id = 'click-link'; Value = @{ label = $name } }) }
            'textbox' { @(@{ Id = 'fill'; Value = @{ field = $name; text = '<text>' } }) }
            'combobox' { @(@{ Id = 'select-option'; Value = @{ option = '<option>'; field = $name } }) }
            'checkbox' { @(@{ Id = 'check'; Value = @{ label = $name } }, @{ Id = 'uncheck'; Value = @{ label = $name } }) }
            'heading' { @(@{ Id = 'expect-heading'; Value = @{ text = $name } }) }
            default { @(@{ Id = 'expect-text'; Value = @{ text = $name } }) }
        })
        foreach ($candidate in $candidates) {
            $phrase = $byId[$candidate.Id]
            if ($null -eq $phrase) { continue }
            $sentence = Format-StepPhraseSentence -Phrase $phrase -Value $candidate.Value
            try {
                $null = @(Resolve-StepPhrase -Sentence $sentence -Surface page -Library $library)
                $suggestions.Add([ordered]@{ step = $sentence; on = 'page' })
            } catch {
                Write-Verbose "The sentence of '$($candidate.Id)' for '$Reference' does not resolve: $($_.Exception.Message)"
            }
        }
        if ($role -cnotin @('button', 'link', 'textbox', 'combobox', 'checkbox', 'heading')) {
            $suggestions.Add([ordered]@{ action = 'webClick'; fields = [ordered]@{ role = $role; name = $name } })
        }
    } else {
        $verb = switch -CaseSensitive ($role) {
            'button' { 'webClick' }
            'link' { 'webClick' }
            'checkbox' { 'webClick' }
            'textbox' { 'webFill' }
            'combobox' { 'webSelect' }
            default { 'webExpect' }
        }
        $suggestions.Add([ordered]@{ action = $verb; fields = [ordered]@{ role = $role; name = $name; nth = $position } })
    }
    return [ordered]@{
        ok          = $true
        ref         = $Reference
        target      = [ordered]@{ role = $role; name = $name }
        suggestions = [object[]]$suggestions.ToArray()
    }
}

function Invoke-WorkloadSuggestRequest {
    <#
    .SYNOPSIS
        The suggest handler: the sentences, or the primitive with nth, that target one entry of the current snapshot.
    .DESCRIPTION
        Uniqueness is judged by the matcher tapOn uses, over every word box of
        the snapshot, so a filtered or cut view never changes the answer. A
        sentence is offered only when the resolver accepts it, and no
        suggestion holds a reference. A page reference is answered from the
        page, by the locator of the page verbs.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    if ($null -eq $Call.Worker.Session) { return (New-WorkloadRefusal -Code 'workload_no_session' -Key 'runner.workload_no_session') }
    $reference = if ($Call.Params -is [System.Collections.IDictionary]) { [string]$Call.Params['ref'] } else { '' }
    $table = $null
    if ($reference -cmatch '^s[1-9][0-9]{0,11}$') { $table = $Call.Worker.Screen.Table }
    elseif ($reference -cmatch '^p[1-9][0-9]{0,11}$') { $table = $Call.Worker.Page.Table }
    if ($null -eq $table -or -not $table.Contains($reference)) {
        return (New-WorkloadRefusal -Code 'workload_stale_reference' -Key 'runner.workload_stale_reference' -Arguments @{ reference = $reference })
    }
    if ($reference.StartsWith('p', [StringComparison]::Ordinal)) { return (Get-WorkloadPageSuggestion -Call $Call -Reference $reference) }
    $entry = $table[$reference]
    $text = [string]$entry.Text
    $library = Get-WorkloadSessionPhraseLibrary -Session $Call.Worker.Session
    $byId = @{}
    foreach ($phrase in @($library.Phrases)) { $byId[[string]$phrase.Id] = $phrase }
    $boxes = @($Call.Worker.Screen.Boxes)
    $contains = Find-OcrWordBoxMatch -Box $boxes -Label $text -MatchMode contains
    $word = Find-OcrWordBoxMatch -Box $boxes -Label $text -MatchMode word

    $candidates = [Collections.Generic.List[object]]::new()
    $candidates.Add(@{ Id = 'wait-for-text'; Value = @{ text = $text } })
    $candidates.Add(@{ Id = 'expect-text'; Value = @{ text = $text } })
    if ($contains.Count -eq 1) { $candidates.Add(@{ Id = 'click'; Value = @{ label = $text } }) }
    if ($word.Count -eq 1) { $candidates.Add(@{ Id = 'click-button'; Value = @{ label = $text } }) }
    $suggestions = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidates) {
        $phrase = $byId[$candidate.Id]
        if ($null -eq $phrase) { continue }
        $sentence = Format-StepPhraseSentence -Phrase $phrase -Value $candidate.Value
        try {
            $null = @(Resolve-StepPhrase -Sentence $sentence -Surface screen -Library $library)
            $suggestions.Add([ordered]@{ step = $sentence; on = 'screen' })
        } catch {
            Write-Verbose "The sentence of '$($candidate.Id)' for '$reference' does not resolve: $($_.Exception.Message)"
        }
    }
    if ($word.Count -gt 1) {
        $left = [int]$entry.X
        $right = $left + [int]$entry.W
        for ($i = 0; $i -lt $word.Count; $i++) {
            $hit = $word[$i]
            if ([int]$hit.block -eq [int]$entry.Block -and [int]$hit.par -eq [int]$entry.Par -and [int]$hit.line -eq [int]$entry.Line -and
                [int]$hit.x -ge $left -and [int]$hit.x -lt $right) {
                $suggestions.Add([ordered]@{ action = 'tapOn'; fields = [ordered]@{ label = $text; match = 'word'; nth = $i + 1 } })
                break
            }
        }
    }
    return [ordered]@{
        ok          = $true
        ref         = $reference
        target      = [ordered]@{ text = $text; box = ('{0},{1},{2},{3}' -f [int]$entry.X, [int]$entry.Y, [int]$entry.W, [int]$entry.H) }
        suggestions = [object[]]$suggestions.ToArray()
    }
}

function Reset-WorkloadSurface {
    <#
    .SYNOPSIS
        Drops the reference tables of both surfaces; the counters and ordinals stay, so an id is never reused.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Clears reference tables this worker keeps in memory.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every caller names its reason; the tables are cleared alike.')]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][ValidateSet('replay-start', 'replay', 'session-end')][string]$Reason
    )
    if (Get-Command Close-GuestWebSession -ErrorAction SilentlyContinue) { [void](Close-GuestWebSession -All -Reason $Reason) }
    $state = $Session['SurfaceState']
    if ($null -eq $state) { return }
    $state.Screen.Table = $null
    $state.Screen.Boxes = @()
    $state.Page.Table = $null
}

function Invoke-WorkloadSessionStartRequest {
    <#
    .SYNOPSIS
        The session.start handler: loads the engine once and attaches the session to a running VM.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    $params = if ($Call.Params -is [System.Collections.IDictionary]) { $Call.Params } else { @{} }
    $paths = Import-WorkloadEngineModule -ConfigPath ([string]$Call.ConfigPath)
    $variables = if ($params['variables'] -is [System.Collections.IDictionary]) { $params['variables'] } else { @{} }
    $r = Start-WorkloadSessionRuntime -Paths $paths -SessionId ([string]$Call.SessionId) -Folder ([string]$Call.SessionDir) `
        -GuestKey ([string]$params['guestKey']) -VMName ([string]$params['vmName']) -Sequence ([string]$params['sequence']) -Variables $variables
    if ($r['ok'] -ne $true) { return $r }
    $session = $r['Session']
    $session.SurfaceState = @{ Screen = $Call.Worker.Screen; Page = $Call.Worker.Page }
    $Call.Worker.Session = $session
    return [ordered]@{
        ok              = $true
        vmName          = [string]$session.VMName
        guestKey        = [string]$session.GuestKey
        hostType        = [string]$session.HostType
        defaultSurface  = 'screen'
        variables       = [object[]]@($session.RawVariables.Keys | ForEach-Object { [string]$_ })
        otherRunningVms = [object[]]@($r['OtherRunningVms'] | ForEach-Object { [string]$_ })
    }
}

function Invoke-WorkloadSessionEndRequest {
    <#
    .SYNOPSIS
        The session.end handler: ends the session and gives the runtime back; the VM keeps running.
    .DESCRIPTION
        Idempotent: the worker shell also calls it on its way out, when the
        session has usually ended already. Only the reason error closes the
        owner cycle as failed; a session has no idle expiry.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    if ($null -eq $Call.Worker.Session) {
        if ($env:YURUNA_RUNTIME_DIR -and (Get-Command Exit-YurunaOneShotLease -ErrorAction SilentlyContinue)) {
            $null = Exit-YurunaOneShotLease -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
        }
        return [ordered]@{ ok = $true; released = $false; cycleFolder = '' }
    }
    $requested = if ($Call.Params -is [System.Collections.IDictionary]) { [string]$Call.Params['reason'] } else { '' }
    $reason = switch -CaseSensitive ($requested) {
        'client-request' { 'ended' }
        'client-ended' { 'client-disconnect' }
        'parent-lost' { 'client-disconnect' }
        default { 'error' }
    }
    try {
        $r = Stop-WorkloadSessionRuntime -Session $Call.Worker.Session -Reason $reason
    } finally {
        $Call.Worker.Session = $null
    }
    return [ordered]@{ ok = $true; released = [bool]$r.Released; cycleFolder = [string]$r.CycleFolder }
}

function Add-WorkloadReplayJournalEntry {
    <#
    .SYNOPSIS
        Journals a replay that failed on its way out, unless the journal holds it already.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][int]$Seq,
        [Parameter(Mandatory)][string]$OperationId,
        [AllowEmptyString()][string]$Sequence,
        [AllowEmptyString()][string]$VmBefore,
        [Parameter(Mandatory)][datetime]$StartedAt
    )
    if (@($Session.Journal | Where-Object { [string]$_['operationId'] -ceq $OperationId }).Count -gt 0) { return }
    try {
        $null = Add-WorkloadJournalEntry -Session $Session -Entry ([ordered]@{
                schema              = 'yuruna.workload-journal/v1'
                seq                 = $Seq
                operationId         = $OperationId
                tool                = 'workload_run_sequence'
                outcome             = 'failed'
                runnable            = $false
                surface             = 'screen'
                authored            = @{ sequence = $Sequence }
                yaml                = ''
                primitives          = [object[]]@()
                completedPrimitives = 0
                failedPrimitive     = 0
                effect              = 'uncertain'
                failureClass        = 'unknown'
                secretInput         = $true
                vmName              = $VmBefore
                vmNameAfter         = [string]$Session.VMName
                startedAtUtc        = (ConvertTo-WorkloadUtcText -Instant $StartedAt)
                endedAtUtc          = (ConvertTo-WorkloadUtcText -Instant ([DateTime]::UtcNow))
            })
    } catch {
        Write-Verbose "Replay operation $Seq was not journaled after it threw: $($_.Exception.Message)"
    }
}

function Invoke-WorkloadSequenceRunRequest {
    <#
    .SYNOPSIS
        The sequence.run handler: replays a sequence's own steps on the attached VM in a child process.
    .DESCRIPTION
        A replay refused before its child started consumes no sequence number,
        enters no sensitive state and is not journaled. Once the child
        started, the replay is counted, the session is sensitive (the worker
        cannot see what the child types) and it is journaled on every way out.
        The handler polls the child and the cancel signal; a poll that throws
        stops the child and is answered as a cancel. An operation id that has
        a result is answered from it and starts no second child.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    if ($null -eq $Call.Worker.Session) { return (New-WorkloadRefusal -Code 'workload_no_session' -Key 'runner.workload_no_session') }
    $Session = $Call.Worker.Session
    $params = if ($Call.Params -is [System.Collections.IDictionary]) { $Call.Params } else { @{} }
    $operationId = [string]$params['operationId']
    if ($Session.Results.ContainsKey($operationId)) { return $Session.Results[$operationId] }
    $sequence = [string]$params['sequence']
    $vmBefore = [string]$Session.VMName
    $startArguments = @{ Session = $Session; Sequence = $sequence; OperationId = $operationId }
    if ($params.Contains('timeoutSeconds') -and $null -ne $params['timeoutSeconds']) { $startArguments.TimeoutSeconds = [int]$params['timeoutSeconds'] }

    $start = $null
    try {
        $start = Start-WorkloadReplay @startArguments
    } catch {
        if ($_.Exception.Data -and $_.Exception.Data['WorkloadReplayChildStarted'] -eq $true) {
            $Session.OperationSeq = [int]$Session.OperationSeq + 1
            $startedSeq = [int]$Session.OperationSeq
            Enter-WorkloadSensitiveState -Session $Session -Seq $startedSeq
            Add-WorkloadReplayJournalEntry -Session $Session -Seq $startedSeq -OperationId $operationId -Sequence $sequence `
                -VmBefore $vmBefore -StartedAt ([DateTime]::UtcNow)
        }
        throw
    }
    if ($start['ok'] -ne $true) { return (ConvertTo-WorkloadOperationRefusal -Refusal $start) }
    $replay = $start['Replay']

    $seq = 0
    try {
        $r = $null
        try {
            $Session.OperationSeq = [int]$Session.OperationSeq + 1
            $seq = [int]$Session.OperationSeq
            Enter-WorkloadSensitiveState -Session $Session -Seq $seq
            if ($null -ne $Call.Progress) { $null = & $Call.Progress 0 1 $sequence }
            $r = Get-WorkloadReplayResult -Session $Session
            while ($null -eq $r) {
                $stop = @()
                if ($null -ne $Call.ShouldStop) { $stop = @(& $Call.ShouldStop) }
                if ($stop.Count -gt 0 -and $stop[-1] -eq $true) {
                    $r = Stop-WorkloadReplay -Session $Session -Reason 'canceled'
                    break
                }
                # A fixed pause between polls; Get-WorkloadReplayResult enforces the replay's limit.
                Start-Sleep -Milliseconds 500
                $r = Get-WorkloadReplayResult -Session $Session
            }
        } catch {
            if ($null -eq $Session.ActiveReplay) { throw }
            Write-Verbose "The replay of '$sequence' is stopped after its polling threw: $($_.Exception.Message)"
            $r = Stop-WorkloadReplay -Session $Session -Reason 'canceled'
        } finally {
            if ($null -ne $Session.ActiveReplay) { $null = Stop-WorkloadReplay -Session $Session -Reason 'canceled' }
        }
        $endedAt = [DateTime]::UtcNow

        $view = $null
        if ($r['failure'] -is [System.Collections.IDictionary]) {
            $view = ConvertTo-WorkloadFailureView -Record $r['failure'] -Session $Session
            $Session.LastFailure = $view
            [IO.File]::WriteAllText([string]$view['evidence']['view'], (ConvertTo-Json -InputObject $view -Depth 12), [Text.UTF8Encoding]::new($false))
        }
        $verdict = [string]$r['verdict']
        $outcome = switch -CaseSensitive ($verdict) { 'passed' { 'passed' } 'canceled' { 'canceled' } default { 'failed' } }
        $null = Add-WorkloadJournalEntry -Session $Session -Entry ([ordered]@{
                schema              = 'yuruna.workload-journal/v1'
                seq                 = $seq
                operationId         = $operationId
                tool                = 'workload_run_sequence'
                outcome             = $outcome
                runnable            = $false
                surface             = 'screen'
                authored            = @{ sequence = $sequence }
                yaml                = ''
                primitives          = [object[]]@()
                completedPrimitives = 0
                failedPrimitive     = 0
                effect              = [string]$r['effect']
                failureClass        = $(if ($r['failure'] -is [System.Collections.IDictionary]) { [string]$r['failure']['failureClass'] } else { '' })
                secretInput         = $true
                vmName              = $vmBefore
                vmNameAfter         = [string]$Session.VMName
                startedAtUtc        = (ConvertTo-WorkloadUtcText -Instant $replay.StartedUtc)
                endedAtUtc          = (ConvertTo-WorkloadUtcText -Instant $endedAt)
            })

        $state = if ($verdict -ceq 'passed') { 'succeeded' } elseif ($verdict -ceq 'canceled' -and $r['childStopped'] -eq $true) { 'canceled' } else { 'failed' }
        $result = [ordered]@{ ok = ($verdict -ceq 'passed'); state = $state }
        foreach ($key in @('verdict', 'effect', 'exitCode', 'sequence', 'sequencePath', 'startStep', 'replayId', 'invocationId', 'operationId',
                'recordState', 'completionRecord', 'reason', 'vmName', 'vmRenamed', 'vmState', 'sessionState', 'failure', 'outputTruncated',
                'durationSeconds', 'childStopped')) {
            $result[$key] = if ($key -ceq 'failure') { $view } else { $r[$key] }
        }
        $Session.Results[$operationId] = $result
        return $result
    } catch {
        if ($seq -eq 0) {
            $Session.OperationSeq = [int]$Session.OperationSeq + 1
            $seq = [int]$Session.OperationSeq
            Enter-WorkloadSensitiveState -Session $Session -Seq $seq
        }
        Add-WorkloadReplayJournalEntry -Session $Session -Seq $seq -OperationId $operationId -Sequence $sequence `
            -VmBefore $vmBefore -StartedAt $replay.StartedUtc
        throw
    }
}

function Invoke-WorkloadSequenceSaveRequest {
    <#
    .SYNOPSIS
        The sequence.save handler: writes the runnable journal entries as a sequence file.
    .DESCRIPTION
        A detached session can still save.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Call)
    if ($null -eq $Call.Worker.Session) { return (New-WorkloadRefusal -Code 'workload_no_session' -Key 'runner.workload_no_session') }
    $Session = $Call.Worker.Session
    $refusal = Get-WorkloadSessionRefusal -Session $Session -Tool 'workload_save_sequence'
    if ($null -ne $refusal) { return $refusal }
    $params = if ($Call.Params -is [System.Collections.IDictionary]) { $Call.Params } else { @{} }
    return (Save-WorkloadSequenceFile -Session $Session -Journal @(Get-WorkloadJournalEntry -Session $Session) -Name ([string]$params['name']) `
            -Description ([string]$params['description']) -Resource ([string[]]@($params['resource'])) -ComponentCount ([int]$params['componentSteps']))
}

Export-ModuleMember -Function Initialize-WorkloadVariableScope, Get-WorkloadAllowedVerb, Test-WorkloadVerb, Test-WorkloadActionField, `
    Test-WorkloadSecretInput, Test-WorkloadIntent, ConvertTo-WorkloadStepYaml, Invoke-WorkloadEngineCall, Invoke-WorkloadStepList, `
    Get-WorkloadEffectState, Invoke-WorkloadOperation, Invoke-WorkloadStepRequest, Invoke-WorkloadActionRequest, `
    Add-WorkloadJournalEntry, Get-WorkloadJournalEntry, Get-WorkloadJournalResult, Get-WorkloadFailureResult, `
    ConvertTo-WorkloadFailureView, Get-WorkloadLastFailure, Enter-WorkloadSensitiveState, Test-WorkloadSensitiveState, `
    Protect-WorkloadReply, Invoke-WorkloadPhraseRequest, Invoke-WorkloadSnapshotRequest, Invoke-WorkloadSuggestRequest, `
    Save-WorkloadScreenSnapshot, Save-WorkloadPageSnapshot, Reset-WorkloadSurface, Invoke-WorkloadSessionStartRequest, Invoke-WorkloadSessionEndRequest, `
    Invoke-WorkloadSequenceRunRequest, Invoke-WorkloadSequenceSaveRequest
