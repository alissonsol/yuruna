<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42c84f5e-5b48-4cbd-9651-5f0cb7f97f12
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization message envelope compatibility redaction
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

<#
.SYNOPSIS
    Construct and validate the versioned condition that crosses a Yuruna
    process, persistence or network boundary.
.DESCRIPTION
    Prose is not identity. The envelope carries one namespaced code and typed,
    JSON-safe arguments; an optional third-party detail is bounded, redacted
    and explicitly sourced. A rendered sentence is derived provenance only.

    The legacy converter is the one dual-read boundary for failureClass,
    reason, errorMessage, event and diagnosticClass. Its removal release and
    date live in the shared fixture rather than in a comment that never ages.
#>

$script:MessageSchema = 'yuruna.message/v1'
$script:MaxArguments = 32
$script:MaxDetailLength = 4096
$script:SafeInteger = [System.Numerics.BigInteger]::Parse('9007199254740991')
$script:SensitiveArgumentName = '(?i)(password|passwd|secret|token|api[_-]?key|apikey|credential)'

function Get-MessageContractRoot {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    return (Join-Path $repoRoot 'globalization')
}

function Test-MessageRecord {
    param([AllowNull()]$Value)
    return ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject])
}

function Test-MessageField {
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Name)
    if ($Record -is [System.Collections.IDictionary]) { return $Record.Contains($Name) }
    return ($Record.PSObject.Properties.Name -ccontains $Name)
}

function Get-MessageField {
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Name)
    if ($Record -is [System.Collections.IDictionary]) { return $Record[$Name] }
    $property = $Record.PSObject.Properties[$Name]
    return $(if ($property) { $property.Value } else { $null })
}

function Get-MessageUnicodeScalarCount {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $count = 0
    foreach ($rune in $Text.EnumerateRunes()) { $count++ }
    return $count
}

function Limit-MessageUnicodeScalar {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Maximum)

    if ((Get-MessageUnicodeScalarCount -Text $Text) -le $Maximum) { return $Text }
    $builder = [Text.StringBuilder]::new()
    $count = 0
    foreach ($rune in $Text.EnumerateRunes()) {
        if ($count -ge $Maximum) { break }
        [void]$builder.Append($rune.ToString())
        $count++
    }
    return $builder.ToString()
}

function ConvertTo-CanonicalDecimalMessageText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($Text.Length -gt 128 -or $Text -cnotmatch '^-?[0-9]+(?:\.[0-9]+)?$') { return $null }
    $negative = $Text.StartsWith('-', [StringComparison]::Ordinal)
    $unsigned = if ($negative) { $Text.Substring(1) } else { $Text }
    $parts = $unsigned.Split('.', 2)
    $whole = $parts[0].TrimStart('0')
    if (-not $whole) { $whole = '0' }
    $fraction = if ($parts.Count -eq 2) { $parts[1].TrimEnd('0') } else { '' }
    $result = if ($fraction) { "$whole.$fraction" } else { $whole }
    if ($negative -and $result -ne '0') { return "-$result" }
    return $result
}

function ConvertTo-CanonicalMessageArgument {
    <#
    .SYNOPSIS
        Convert one declared catalog type to its portable JSON representation.
    #>
    [CmdletBinding()]
    [OutputType([string], [long], [System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][ValidateSet('text', 'identifier', 'detail', 'integer', 'decimal', 'bytes', 'duration', 'datetime', 'token')]
        [string]$Type,
        [Parameter(Mandatory)][AllowNull()]$Value
    )

    if ($null -eq $Value) { return $null }
    switch ($Type) {
        { $_ -in @('text', 'identifier', 'detail', 'token') } {
            $text = [string]$Value
            if ((Get-MessageUnicodeScalarCount -Text $text) -gt 4096) {
                throw "A $Type message argument exceeds 4096 characters."
            }
            return $text
        }
        'integer' {
            $number = [System.Numerics.BigInteger]::Parse(
                ([string]$Value), [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture)
            if ([System.Numerics.BigInteger]::Abs($number) -le $script:SafeInteger) { return [long]$number }
            return [ordered]@{ '$type' = 'integer'; value = $number.ToString([Globalization.CultureInfo]::InvariantCulture) }
        }
        'decimal' {
            $text = ConvertTo-CanonicalDecimalMessageText -Text ([string]$Value)
            if ($null -eq $text) { throw "Invalid bounded invariant decimal argument '$Value'." }
            return [ordered]@{ '$type' = 'decimal'; value = $text }
        }
        'bytes' {
            $number = [System.Numerics.BigInteger]::Parse(
                ([string]$Value), [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture)
            if ($number -lt [System.Numerics.BigInteger]::Zero) { throw 'A byte count cannot be negative.' }
            return [ordered]@{ '$type' = 'bytes'; value = $number.ToString([Globalization.CultureInfo]::InvariantCulture) }
        }
        'duration' {
            if ($Value -is [TimeSpan]) {
                $milliseconds = [System.Numerics.BigInteger][Math]::Floor($Value.TotalMilliseconds)
            } else {
                $milliseconds = [System.Numerics.BigInteger]::Parse(
                    ([string]$Value), [Globalization.NumberStyles]::Integer,
                    [Globalization.CultureInfo]::InvariantCulture)
            }
            if ($milliseconds -lt [System.Numerics.BigInteger]::Zero) { throw 'A duration cannot be negative.' }
            return [ordered]@{ '$type' = 'duration'; milliseconds = $milliseconds.ToString([Globalization.CultureInfo]::InvariantCulture) }
        }
        'datetime' {
            $when = if ($Value -is [DateTimeOffset]) { $Value } elseif ($Value -is [DateTime]) {
                $dateTime = [DateTime]$Value
                # An unspecified DateTime carries no offset to convert. Treat it
                # as UTC, the same explicit policy used for an offset-free wire
                # string, rather than borrowing the host's local time zone.
                if ($dateTime.Kind -eq [DateTimeKind]::Unspecified) {
                    $dateTime = [DateTime]::SpecifyKind($dateTime, [DateTimeKind]::Utc)
                }
                [DateTimeOffset]::new($dateTime)
            } else {
                [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal)
            }
            return [ordered]@{
                '$type' = 'datetime'
                value = $when.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
            }
        }
    }
}

function Protect-MessageDetail {
    <#
    .SYNOPSIS
        Bound and redact untrusted third-party prose before persistence.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source,
        [AllowEmptyCollection()][string[]]$Secret = @()
    )

    $safeSource = $Source.Trim().ToLowerInvariant()
    if ($safeSource -cnotmatch '^[a-z][a-z0-9_.-]{0,127}$') { throw "Detail source '$Source' is not a stable source token." }
    $safe = $Text
    $safe = [regex]::Replace($safe, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
    foreach ($value in @($Secret | Where-Object { $_ })) {
        $safe = [regex]::Replace($safe, [regex]::Escape($value), '[REDACTED]',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $safe = [regex]::Replace($safe, '(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)\b(password|passwd|secret|token|credential|api[_-]?key)\s*[:=]\s*[^\s,;]+', '$1=[REDACTED]')
    $safe = Limit-MessageUnicodeScalar -Text $safe -Maximum $script:MaxDetailLength
    return [ordered]@{ text = $safe; source = $safeSource }
}

function New-MessageEnvelope {
    <#
    .SYNOPSIS
        Build a validated canonical Yuruna message envelope.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns an immutable wire value; changes nothing.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Code,
        [hashtable]$Arguments = @{},
        [hashtable]$ArgumentTypes = @{},
        [AllowEmptyString()][string]$DetailText,
        [string]$DetailSource = 'external',
        [AllowEmptyCollection()][string[]]$Secret = @(),
        [hashtable]$Rendered
    )

    if ($Code -cnotmatch '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' -or $Code.Length -gt 128) {
        throw "Message code '$Code' is not a bounded namespaced code."
    }
    if (@($Arguments.Keys).Count -gt $script:MaxArguments) { throw "A message envelope may carry at most $script:MaxArguments arguments." }
    $canonical = [ordered]@{}
    foreach ($name in @($Arguments.Keys | Sort-Object)) {
        if ([string]$name -cnotmatch '^[a-z][A-Za-z0-9]{0,63}$') { throw "Message argument name '$name' is invalid." }
        if ([string]$name -match $script:SensitiveArgumentName) {
            throw "Message argument '$name' looks credential-bearing; secrets do not belong in persisted arguments."
        }
        if (-not $ArgumentTypes.ContainsKey($name)) { throw "Message argument '$name' has no declared type." }
        $canonical[$name] = ConvertTo-CanonicalMessageArgument -Type ([string]$ArgumentTypes[$name]) -Value $Arguments[$name]
    }

    $result = [ordered]@{ schema = $script:MessageSchema; code = $Code; args = $canonical }
    if ($PSBoundParameters.ContainsKey('DetailText')) {
        $result.detail = Protect-MessageDetail -Text $DetailText -Source $DetailSource -Secret $Secret
    }
    if ($Rendered) {
        foreach ($required in @('text', 'messageKey', 'locale', 'catalogHash')) {
            if (-not $Rendered.ContainsKey($required)) { throw "Rendered provenance has no '$required'." }
        }
        $result.rendered = [ordered]@{
            text = [string]$Rendered.text
            messageKey = [string]$Rendered.messageKey
            locale = [string]$Rendered.locale
            catalogHash = [string]$Rendered.catalogHash
            authoritative = $false
        }
    }
    if (-not (Test-MessageEnvelope -Envelope $result)) { throw 'The constructed message envelope did not satisfy its schema.' }
    return $result
}

function Test-MessageEnvelope {
    <#
    .SYNOPSIS
        Test a Yuruna message envelope against its schema and safety rules.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Envelope,
        [string]$SchemaPath = (Join-Path (Get-MessageContractRoot) 'schema/message.schema.json'),
        [AllowEmptyCollection()][string[]]$Secret = @()
    )

    try {
        $json = if ($Envelope -is [string]) { $Envelope } else { $Envelope | ConvertTo-Json -Depth 20 -Compress }
        if (-not (Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop)) { return $false }
        $doc = if ($Envelope -is [string]) { ConvertFrom-Json -InputObject $Envelope } else { $Envelope }
        $argumentNames = if ($doc.args -is [System.Collections.IDictionary]) {
            @($doc.args.Keys | ForEach-Object { [string]$_ })
        } else { @($doc.args.PSObject.Properties.Name) }
        foreach ($name in $argumentNames) {
            if ($name -match $script:SensitiveArgumentName) { return $false }
            $value = Get-MessageField -Record $doc.args -Name $name
            if (-not (Test-MessageRecord -Value $value) -or
                -not (Test-MessageField -Record $value -Name '$type')) { continue }
            $type = [string](Get-MessageField -Record $value -Name '$type')
            if ($type -eq 'integer') {
                $text = [string](Get-MessageField -Record $value -Name 'value')
                if ($text -cnotmatch '^(?:0|[1-9][0-9]*|-[1-9][0-9]*)$') { return $false }
            } elseif ($type -eq 'decimal') {
                $text = [string](Get-MessageField -Record $value -Name 'value')
                $canonical = ConvertTo-CanonicalDecimalMessageText -Text $text
                if ($null -eq $canonical -or
                    -not [string]::Equals($canonical, $text, [StringComparison]::Ordinal)) { return $false }
            } elseif ($type -eq 'datetime') {
                $raw = Get-MessageField -Record $value -Name 'value'
                $text = if ($raw -is [DateTime]) {
                    ([DateTime]$raw).ToUniversalTime().ToString(
                        'yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
                } elseif ($raw -is [DateTimeOffset]) {
                    ([DateTimeOffset]$raw).ToUniversalTime().ToString(
                        'yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
                } else { [string]$raw }
                $when = [DateTimeOffset]::MinValue
                $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
                    [Globalization.DateTimeStyles]::AdjustToUniversal
                if (-not [DateTimeOffset]::TryParseExact($text, 'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                        [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$when) -or
                    -not [string]::Equals($when.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',
                            [Globalization.CultureInfo]::InvariantCulture), $text,
                        [StringComparison]::Ordinal)) { return $false }
            }
        }
        if (Test-MessageField -Record $doc -Name 'detail') {
            $detail = Get-MessageField -Record $doc -Name 'detail'
            $detailText = [string](Get-MessageField -Record $detail -Name 'text')
            $detailSource = [string](Get-MessageField -Record $detail -Name 'source')
            $protected = Protect-MessageDetail -Text $detailText -Source $detailSource -Secret $Secret
            if (-not [string]::Equals($protected.text, $detailText, [StringComparison]::Ordinal) -or
                -not [string]::Equals($protected.source, $detailSource, [StringComparison]::Ordinal)) { return $false }
        }
        return $true
    } catch { return $false }
}

function ConvertTo-MessageEnvelope {
    <#
    .SYNOPSIS
        Dual-read one v1 envelope or one named legacy record.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$InputObject, [AllowEmptyCollection()][string[]]$Secret = @())

    if (-not (Test-MessageRecord -Value $InputObject)) { throw 'A message record must be an object.' }
    $nested = Get-MessageField -Record $InputObject -Name 'message'
    if ((Test-MessageField -Record $InputObject -Name 'message') -and (Test-MessageRecord -Value $nested) -and
        (Get-MessageField -Record $nested -Name 'schema') -eq $script:MessageSchema) {
        return ConvertTo-MessageEnvelope -InputObject $nested -Secret $Secret
    }
    if ((Get-MessageField -Record $InputObject -Name 'schema') -eq $script:MessageSchema) {
        if (-not (Test-MessageEnvelope -Envelope $InputObject -Secret $Secret)) { throw 'The yuruna.message/v1 envelope is invalid.' }
        return $InputObject
    }

    $code = ''
    $detailText = ''
    $detailSource = 'legacy.record'
    if ((Test-MessageField -Record $InputObject -Name 'failureClass') -and
        (Get-MessageField -Record $InputObject -Name 'failureClass')) {
        $code = 'failure.' + ([string](Get-MessageField -Record $InputObject -Name 'failureClass')).ToLowerInvariant()
        $detailSource = 'legacy.failure'
    } elseif ((Test-MessageField -Record $InputObject -Name 'event') -and
        (Get-MessageField -Record $InputObject -Name 'event')) {
        $eventName = ([string](Get-MessageField -Record $InputObject -Name 'event')).ToLowerInvariant() -replace '_', '.'
        $code = if ($eventName -match '\.') { $eventName } else { 'event.' + $eventName }
        $detailSource = 'legacy.event'
    } elseif ((Test-MessageField -Record $InputObject -Name 'diagnosticClass') -and
        (Get-MessageField -Record $InputObject -Name 'diagnosticClass')) {
        $code = 'diagnostic.' + ([string](Get-MessageField -Record $InputObject -Name 'diagnosticClass')).ToLowerInvariant()
        $detailSource = 'legacy.diagnostic'
    } else {
        $code = 'legacy.condition'
    }
    $code = $code -replace '[^a-z0-9_.]', '_'
    if ((Test-MessageField -Record $InputObject -Name 'errorMessage') -and
        (Get-MessageField -Record $InputObject -Name 'errorMessage')) {
        $detailText = [string](Get-MessageField -Record $InputObject -Name 'errorMessage')
    } elseif ((Test-MessageField -Record $InputObject -Name 'reason') -and
        (Get-MessageField -Record $InputObject -Name 'reason')) {
        $detailText = [string](Get-MessageField -Record $InputObject -Name 'reason')
    }
    if ($detailText) {
        return New-MessageEnvelope -Code $code -DetailText $detailText -DetailSource $detailSource -Secret $Secret
    }
    return New-MessageEnvelope -Code $code
}

function ConvertTo-MessageCompatibilityRecord {
    <#
    .SYNOPSIS
        Build the dual-write wrapper for the bounded N/N-1 migration window.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Envelope)

    $message = ConvertTo-MessageEnvelope -InputObject $Envelope
    $record = [ordered]@{ message = $message }
    $parts = ([string]$message.code).Split('.', 2)
    switch ($parts[0]) {
        'failure' { $record.failureClass = $parts[1] }
        'diagnostic' { $record.diagnosticClass = $parts[1] }
        'event' { $record.event = $parts[1] }
        'step' { $record.event = [string]$message.code }
    }
    if (Test-MessageField -Record $message -Name 'detail') {
        $record.reason = [string]$message.detail.text
        $record.errorMessage = [string]$message.detail.text
    }
    return $record
}

function Get-MessageMigrationPolicy {
    <#
    .SYNOPSIS
        Read the authoritative N/N-1 message-migration policy.
    #>
    [CmdletBinding()]
    param()
    $path = Join-Path (Get-MessageContractRoot) 'fixtures/message-envelope.json'
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
}

Export-ModuleMember -Function ConvertTo-CanonicalMessageArgument, Protect-MessageDetail,
    New-MessageEnvelope, Test-MessageEnvelope, ConvertTo-MessageEnvelope,
    ConvertTo-MessageCompatibilityRecord, Get-MessageMigrationPolicy
