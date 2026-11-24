<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4211e74f-c194-4278-bd89-51736e031e9c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence secret filter
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

# The secret filter of a workload authoring session. Every value a session
# learns to be secret (a variable named like a password, an authentication
# extension result, a value a sensitive step uses) is registered here, and
# everything the session returns or writes passes through
# Protect-SequenceSecretText or Protect-SequenceSecretObject first.
#
# The engine loads this module in every process, so a runner cycle carries it
# too; the filter stays off there. It is on only when YURUNA_SECRET_FILTER is
# 1 when the module first loads, or after Enable-SequenceSecretFilter, which
# the workload worker calls. Both stores are anchored registries, so a forced
# re-import of the engine (which re-imports this module) keeps the registered
# values and the switch.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Test.Registry anchors both stores under a global name so a -Force re-import keeps the registered values.')]
param()

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Global -Force -DisableNameChecking

# A value shorter than this is too common to mask without masking ordinary
# text, so it is counted and skipped instead.
$script:SecretMinimumLength = 4
# The OCR-tolerant mask compares normalized lines; a shorter normalized form
# would match unrelated screen lines.
$script:SecretMinimumNormalizedLength = 6
$script:SecretMask = '***'
$script:SecretExtensionArea = @('authentication')
# The same pattern Protect-GuestEvidenceText (Test.Diagnostic.psm1) uses to
# decide that a variable holds a secret.
$script:SecretNamePattern = '(?i)password|passwd|secret|token|credential|private.?key'
$script:SecretExtensionPattern = '\$\{ext:([A-Za-z0-9_-]+)\.([A-Za-z][A-Za-z0-9_-]*)\(([^)]*)\)\}'
$script:SecretVariablePattern = '\$\{([^}]+)\}'
$script:SecretDollarSentinel = [char]0xE000
# Deeper than this, a structure is not copied: a string is masked whole.
$script:SecretMaximumDepth = 32

# Ordinal stores: two secrets that differ only in letter case are two values.
$script:SecretValueRegistry = New-YurunaRegistry -Name 'SequenceSecretValue' -Comparer 'Ordinal'
$script:SecretStateRegistry = New-YurunaRegistry -Name 'SequenceSecretState' -Comparer 'Ordinal'

# A key that exists already is kept, so a re-import neither turns the filter
# off nor forgets its counters.
$seedState = [ordered]@{
    Enabled      = ($env:YURUNA_SECRET_FILTER -eq '1')
    StepDepth    = 0
    ShortSkipped = 0
    MaskFailed   = 0
}
foreach ($seedKey in $seedState.Keys) {
    if (-not (& $script:SecretStateRegistry.Has $seedKey)) {
        & $script:SecretStateRegistry.Register $seedKey $seedState[$seedKey]
    }
}

function Get-SequenceSecretStateValue {
    # Private: one value of the state store.
    param([Parameter(Mandatory)][string]$Name)
    return (& $script:SecretStateRegistry.Get $Name)
}

function Set-SequenceSecretStateValue {
    # Private: write one value of the state store.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes one in-memory state value of the secret filter.')]
    param([Parameter(Mandatory)][string]$Name, $Value)
    & $script:SecretStateRegistry.Register $Name $Value
}

function Enable-SequenceSecretFilter {
    <#
    .SYNOPSIS
        Turns the secret filter on for this process.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()
    Set-SequenceSecretStateValue -Name 'Enabled' -Value $true
}

function Disable-SequenceSecretFilter {
    <#
    .SYNOPSIS
        Turns the secret filter off for this process; registered values stay.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()
    Set-SequenceSecretStateValue -Name 'Enabled' -Value $false
}

function Test-SequenceSecretFilterEnabled {
    <#
    .SYNOPSIS
        Whether the secret filter is on.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Get-SequenceSecretStateValue -Name 'Enabled')
}

function Register-SequenceSecret {
    <#
    .SYNOPSIS
        Registers one secret value; returns whether it is now masked.
    .DESCRIPTION
        Returns $false while the filter is off and for an empty value. A value
        shorter than four characters is counted under shortSkipped and not
        stored. A value stored for the first time is handed to the workload
        front end's log filter when Send-WorkloadMask is loaded; an answer
        other than $true counts under maskFailed. Runner processes load this
        module without any workload module, so the sink is optional.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Value,
        [AllowEmptyString()][string]$Source = ''
    )
    if (-not (Test-SequenceSecretFilterEnabled)) { return $false }
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value.Length -lt $script:SecretMinimumLength) {
        Set-SequenceSecretStateValue -Name 'ShortSkipped' -Value ([int](Get-SequenceSecretStateValue -Name 'ShortSkipped') + 1)
        return $false
    }
    if (& $script:SecretValueRegistry.Has $Value) { return $true }
    & $script:SecretValueRegistry.Register $Value $Source
    if (Get-Command Send-WorkloadMask -ErrorAction SilentlyContinue) {
        $answer = $false
        try {
            $answer = Send-WorkloadMask -Value @($Value)
        } catch {
            Write-Verbose "The workload mask sink refused a value: $($_.Exception.Message)"
            $answer = $false
        }
        if ($true -ne $answer) {
            Set-SequenceSecretStateValue -Name 'MaskFailed' -Value ([int](Get-SequenceSecretStateValue -Name 'MaskFailed') + 1)
        }
    }
    return $true
}

function Register-SequenceSecretVariable {
    <#
    .SYNOPSIS
        Registers each string value whose variable name reads like a secret.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([AllowNull()][System.Collections.IDictionary]$Variables)
    if ($null -eq $Variables) { return }
    foreach ($key in @($Variables.Keys)) {
        $value = $Variables[$key]
        if ($value -is [string] -and [string]$key -match $script:SecretNamePattern) {
            $null = Register-SequenceSecret -Value $value -Source "variable:$key"
        }
    }
}

function Register-SequenceSecretFromExtension {
    <#
    .SYNOPSIS
        Registers an extension result that is secret.
    .DESCRIPTION
        An authentication extension result is always secret; any other area's
        result is secret only while a sensitive step runs.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowEmptyString()][string]$Area,
        [AllowEmptyString()][AllowNull()][string]$Value
    )
    $depth = [int](Get-SequenceSecretStateValue -Name 'StepDepth')
    if ($script:SecretExtensionArea -contains $Area -or $depth -gt 0) {
        $null = Register-SequenceSecret -Value $Value -Source "extension:$Area"
    }
}

function Enter-SequenceSecretStep {
    <#
    .SYNOPSIS
        Marks the start of a sensitive step and registers the variables it uses.
    .DESCRIPTION
        Raises the step depth, so an extension result computed while the step
        runs is registered, then registers the value of every ${name} in the
        step's text (else its command) that names a variable. The arguments of
        an extension call are left alone: only the call's result is secret, and
        Register-SequenceSecretFromExtension registers it once computed.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Step,
        [AllowNull()][System.Collections.IDictionary]$Variables
    )
    # The depth rises even for a step with no text, because Exit-SequenceSecretStep
    # always lowers it.
    Set-SequenceSecretStateValue -Name 'StepDepth' -Value ([int](Get-SequenceSecretStateValue -Name 'StepDepth') + 1)
    if ($null -eq $Step) { return }
    $field = $null
    if ($Step.Contains('text') -and $null -ne $Step['text']) { $field = [string]$Step['text'] }
    elseif ($Step.Contains('command') -and $null -ne $Step['command']) { $field = [string]$Step['command'] }
    if ([string]::IsNullOrEmpty($field) -or $null -eq $Variables) { return }
    $rest = $field.Replace('$$', [string]$script:SecretDollarSentinel)
    $rest = [regex]::Replace($rest, $script:SecretExtensionPattern, '')
    foreach ($match in [regex]::Matches($rest, $script:SecretVariablePattern)) {
        $name = $match.Groups[1].Value
        if ($name.Contains(':') -or -not $Variables.Contains($name)) { continue }
        $null = Register-SequenceSecret -Value ([string]$Variables[$name]) -Source "step:$name"
    }
}

function Exit-SequenceSecretStep {
    <#
    .SYNOPSIS
        Marks the end of a sensitive step.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()
    $depth = [int](Get-SequenceSecretStateValue -Name 'StepDepth')
    Set-SequenceSecretStateValue -Name 'StepDepth' -Value ([Math]::Max(0, $depth - 1))
}

function Get-SequenceSecretSpelling {
    # Private: every spelling of every registered value, longest first, then ordinal.
    [OutputType([string[]])]
    param()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in @($script:SecretValueRegistry.Store[0].Keys)) {
        $text = [string]$value
        $json = ConvertTo-Json -InputObject $text -Compress
        if ($json.Length -ge 2) { $json = $json.Substring(1, $json.Length - 2) }
        $candidates = @($text, $json, [uri]::EscapeDataString($text))
        if ($text.Contains("'")) { $candidates += $text.Replace("'", "''") }
        foreach ($candidate in $candidates) {
            if (-not [string]::IsNullOrEmpty($candidate)) { $null = $seen.Add($candidate) }
        }
    }
    $list = [Collections.Generic.List[string]]::new($seen)
    $list.Sort([Comparison[string]] {
            param($a, $b)
            if ($a.Length -ne $b.Length) { return $b.Length.CompareTo($a.Length) }
            return [string]::CompareOrdinal($a, $b)
        })
    return , ([string[]]$list.ToArray())
}

function Protect-SequenceSecretText {
    <#
    .SYNOPSIS
        Returns the text with every spelling of every registered value replaced by ***.
    .DESCRIPTION
        The spellings of a value are the value itself, its JSON string form, its
        URL-escaped form and, when it holds a single quote, the form with each
        quote doubled. They are replaced longest first, ordinally. With
        -OcrTolerant, a line whose OCR-normalized form contains the normalized
        form of a value (of at least six characters) is replaced whole, which
        catches a value an OCR engine misread.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [switch]$OcrTolerant
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($script:SecretValueRegistry.Store[0].Count -eq 0) { return $Text }
    $result = $Text
    foreach ($spelling in (Get-SequenceSecretSpelling)) {
        $result = $result.Replace($spelling, $script:SecretMask, [StringComparison]::Ordinal)
    }
    if ($OcrTolerant -and (Get-Command Get-OCRNormalized -ErrorAction SilentlyContinue)) {
        $normalizedValues = [Collections.Generic.List[string]]::new()
        foreach ($value in @($script:SecretValueRegistry.Store[0].Keys)) {
            $normalized = Get-OCRNormalized -Text ([string]$value)
            if ($normalized.Length -ge $script:SecretMinimumNormalizedLength) { $normalizedValues.Add($normalized) }
        }
        if ($normalizedValues.Count -gt 0) {
            $lines = $result.Split("`n")
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                $body = $line.TrimEnd("`r")
                $lineNormalized = Get-OCRNormalized -Text $body
                foreach ($normalized in $normalizedValues) {
                    if ($lineNormalized.Contains($normalized, [StringComparison]::Ordinal)) {
                        $lines[$i] = $script:SecretMask + $line.Substring($body.Length)
                        break
                    }
                }
            }
            $result = $lines -join "`n"
        }
    }
    return $result
}

function Copy-SequenceSecretValue {
    # Private: the filtered copy of one value at a nesting depth.
    param($Value, [int]$Depth, [switch]$OcrTolerant)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Depth -ge $script:SecretMaximumDepth) { return $script:SecretMask }
        return (Protect-SequenceSecretText -Text $Value -OcrTolerant:$OcrTolerant)
    }
    if ($Depth -ge $script:SecretMaximumDepth) { return , $Value }
    $next = $Depth + 1
    if ($Value -is [System.Collections.IDictionary]) {
        # OrderedHashtable derives from Hashtable, so it is tested first.
        if ($Value -is [System.Collections.Specialized.OrderedDictionary] -or
            $Value -is [System.Management.Automation.OrderedHashtable]) {
            $copy = [ordered]@{}
        } elseif ($Value -is [hashtable]) {
            $copy = @{}
        } else {
            $copy = [ordered]@{}
        }
        foreach ($key in @($Value.Keys)) {
            $copy[$key] = Copy-SequenceSecretValue -Value $Value[$key] -Depth $next -OcrTolerant:$OcrTolerant
        }
        return , $copy
    }
    if ($Value -is [string[]]) {
        $strings = [string[]]::new($Value.Length)
        for ($i = 0; $i -lt $Value.Length; $i++) {
            $strings[$i] = Copy-SequenceSecretValue -Value $Value[$i] -Depth $next -OcrTolerant:$OcrTolerant
        }
        return , $strings
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((Copy-SequenceSecretValue -Value $item -Depth $next -OcrTolerant:$OcrTolerant))
        }
        return , ([object[]]$items.ToArray())
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = Copy-SequenceSecretValue -Value $property.Value -Depth $next -OcrTolerant:$OcrTolerant
        }
        return [pscustomobject]$copy
    }
    return , $Value
}

function Protect-SequenceSecretObject {
    <#
    .SYNOPSIS
        Returns a deep copy of the object with every string filtered.
    .DESCRIPTION
        Returns the object itself while no value is registered. A dictionary
        keeps its kind (ordered stays ordered, a plain hashtable stays a plain
        hashtable), a string array stays a string array, any other collection
        becomes an object array and a custom object a new custom object. A
        copied plain hashtable may enumerate its keys in another order than the
        original, because string hash codes differ from one process to the
        next; compare such a map by its sorted keys.
    #>
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param(
        [AllowNull()]$InputObject,
        [switch]$OcrTolerant
    )
    if ($script:SecretValueRegistry.Store[0].Count -eq 0) { return , $InputObject }
    return , (Copy-SequenceSecretValue -Value $InputObject -Depth 0 -OcrTolerant:$OcrTolerant)
}

function Test-SequenceSecretText {
    <#
    .SYNOPSIS
        Whether the text contains a registered value, compared ordinally.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($value in @($script:SecretValueRegistry.Store[0].Keys)) {
        if ($Text.Contains([string]$value, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-SequenceSecretStat {
    <#
    .SYNOPSIS
        The state of the filter: whether it is on and its counters.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return [ordered]@{
        enabled      = (Test-SequenceSecretFilterEnabled)
        count        = [int]$script:SecretValueRegistry.Store[0].Count
        shortSkipped = [int](Get-SequenceSecretStateValue -Name 'ShortSkipped')
        maskFailed   = [int](Get-SequenceSecretStateValue -Name 'MaskFailed')
    }
}

function Clear-SequenceSecret {
    <#
    .SYNOPSIS
        Forgets every registered value and zeroes the counters; the switch stays.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()
    & $script:SecretValueRegistry.Clear
    Set-SequenceSecretStateValue -Name 'StepDepth' -Value 0
    Set-SequenceSecretStateValue -Name 'ShortSkipped' -Value 0
    Set-SequenceSecretStateValue -Name 'MaskFailed' -Value 0
}

Export-ModuleMember -Function Enable-SequenceSecretFilter, Disable-SequenceSecretFilter, Test-SequenceSecretFilterEnabled, `
    Register-SequenceSecret, Register-SequenceSecretVariable, Register-SequenceSecretFromExtension, `
    Enter-SequenceSecretStep, Exit-SequenceSecretStep, Protect-SequenceSecretText, Protect-SequenceSecretObject, `
    Test-SequenceSecretText, Get-SequenceSecretStat, Clear-SequenceSecret
