<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42ef34a5-9287-4a5d-ae47-d7c1c0a62f98
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization message envelope compatibility redaction
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
    Hold the yuruna.message/v1 boundary to typed identity, bounded untrusted
    detail and one dated legacy migration.
.DESCRIPTION
    These tests cover new/new, old/new and new/old producer/consumer pairings.
    They assert codes and typed values, never catalog wording.

    Run: Invoke-Pester -Path test/modules/Test.Message.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Message.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:SchemaPath = Join-Path $script:RepoRoot 'globalization/schema/message.schema.json'
$script:Fixture = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
    (Join-Path $script:RepoRoot 'globalization/fixtures/message-envelope.json')))
}

Describe 'yuruna.message/v1 has one strict wire shape' {

    It 'constructs schema-valid canonical arguments without guessing their type' {
        $messageArguments = @{
            count = 7
            huge = '9007199254740992'
            ratio = '1234.500'
            size = '18446744073709551615'
            elapsed = [TimeSpan]::FromMilliseconds(90500)
            when = [DateTimeOffset]'2026-09-03T12:34:56Z'
            name = 'machine alpha'
        }
        $types = @{
            count = 'integer'; huge = 'integer'; ratio = 'decimal'; size = 'bytes'
            elapsed = 'duration'; when = 'datetime'; name = 'text'
        }
        $envelope = New-MessageEnvelope -Code 'pool.assignment_blocked' -Arguments $messageArguments -ArgumentTypes $types

        Assert-True (Test-MessageEnvelope -Envelope $envelope -SchemaPath $script:SchemaPath) 'the constructor emitted an invalid envelope'
        Assert-Equal -Expected 7 -Actual $envelope.args.count 'a JavaScript-safe integer should stay a JSON number'
        Assert-StringEqual -Expected 'integer' -Actual $envelope.args.huge.'$type' 'a large integer lost its type'
        Assert-StringEqual -Expected '9007199254740992' -Actual $envelope.args.huge.value 'a large integer was rounded'
        Assert-StringEqual -Expected '1234.5' -Actual $envelope.args.ratio.value 'a decimal is not canonical'
        Assert-StringEqual -Expected '18446744073709551615' -Actual $envelope.args.size.value 'a byte count was narrowed'
        Assert-StringEqual -Expected '90500' -Actual $envelope.args.elapsed.milliseconds 'a duration changed units'
        Assert-StringEqual -Expected '2026-09-03T12:34:56.0000000Z' -Actual $envelope.args.when.value 'a time is not fixed UTC'
    }

    It 'serializes a DateTime directly without borrowing the current culture' {
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        $originalUiCulture = [Globalization.CultureInfo]::CurrentUICulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
            [Globalization.CultureInfo]::CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
            $when = [DateTime]::SpecifyKind([DateTime]::new(2026, 9, 3, 12, 34, 56), [DateTimeKind]::Utc)
            $argument = ConvertTo-CanonicalMessageArgument -Type datetime -Value $when
            Assert-StringEqual -Expected '2026-09-03T12:34:56.0000000Z' -Actual $argument.value `
                'DateTime was stringified through the host culture before parsing'
        } finally {
            [Globalization.CultureInfo]::CurrentCulture = $originalCulture
            [Globalization.CultureInfo]::CurrentUICulture = $originalUiCulture
        }
    }

    It 'preserves decomposed Unicode exactly at the message boundary' {
        $case = $script:Fixture.unicodePreservation
        $expected = [string]$case.decomposed
        Assert-False $expected.IsNormalized([Text.NormalizationForm]::FormC) `
            'the shared preservation fixture is accidentally NFC already'
        foreach ($type in @($case.argumentTypes)) {
            $actual = [string](ConvertTo-CanonicalMessageArgument -Type ([string]$type) -Value $expected)
            Assert-True ([string]::Equals($expected, $actual, [StringComparison]::Ordinal)) `
                "$type argument bytes were normalized at the wire boundary"
        }
        $detail = Protect-MessageDetail -Text $expected -Source ([string]$case.detailSource)
        Assert-True ([string]::Equals($expected, $detail.text, [StringComparison]::Ordinal)) `
            'untrusted detail was normalized instead of only sanitized/redacted'
    }

    It 'accepts the shared long decimal without narrowing it to System.Decimal' {
        $bounds = $script:Fixture.wireBounds
        $value = [string]$bounds.longDecimalDigit * [int]$bounds.longDecimalLength
        $argument = ConvertTo-CanonicalMessageArgument -Type decimal -Value $value
        Assert-StringEqual -Expected $value -Actual $argument.value `
            'the decimal producer narrowed or rounded a schema-valid decimal string'
        Assert-Throw {
            ConvertTo-CanonicalMessageArgument -Type decimal -Value ($value + $bounds.longDecimalDigit)
        } 'bounded invariant decimal' 'a decimal longer than the wire bound was emitted'
    }

    It 'counts and truncates astral text by Unicode scalar without splitting a surrogate pair' {
        $bounds = $script:Fixture.wireBounds
        $astral = [string]$bounds.astral
        $atLimit = $astral * [int]$bounds.maxScalars
        $argument = [string](ConvertTo-CanonicalMessageArgument -Type text -Value $atLimit)
        Assert-StringEqual -Expected $atLimit -Actual $argument `
            'a scalar-bounded argument was rejected because UTF-16 uses two code units'
        Assert-Throw {
            ConvertTo-CanonicalMessageArgument -Type text -Value ($atLimit + $astral)
        } 'exceeds 4096' 'an argument over the scalar bound was accepted'

        $detail = Protect-MessageDetail -Text ($atLimit + $astral) -Source 'tool.stderr'
        Assert-StringEqual -Expected $atLimit -Actual $detail.text `
            'detail truncation split an astral scalar or counted UTF-16 code units'
        Assert-False $detail.text.EndsWith([string][char]0xd83d) `
            'detail truncation left a dangling high surrogate'
    }

    It 'requires every argument type instead of inferring it from a string' {
        Assert-Throw {
            New-MessageEnvelope -Code 'pool.assignment_blocked' -Arguments @{ count = '7' }
        } 'no declared type' 'the producer guessed whether a string was a count'
    }

    It 'rejects unknown fields and noncanonical typed values through the real schema' {
        $bad = @{
            schema = 'yuruna.message/v1'
            code = 'pool.assignment_blocked'
            args = @{ count = @{ '$type' = 'integer'; value = '007' } }
            wording = 'branch on me'
        }
        Assert-False (Test-MessageEnvelope -Envelope $bad -SchemaPath $script:SchemaPath) 'a field or encoding forbidden by message.schema.json passed'
    }

    It 'semantically rejects every schema-shaped noncanonical typed fixture' {
        foreach ($case in @($script:Fixture.invalidTypedArguments)) {
            $bad = [ordered]@{
                schema = 'yuruna.message/v1'
                code = 'pool.assignment_blocked'
                args = [ordered]@{ value = $case.value }
            }
            Assert-False (Test-MessageEnvelope -Envelope $bad -SchemaPath $script:SchemaPath) `
                "'$($case.name)' passed semantic validation"
            Assert-Throw { ConvertTo-MessageEnvelope -InputObject $bad } 'envelope is invalid' `
                "the direct reader accepted '$($case.name)'"
        }
    }

    It 'marks rendered prose as derived and carries all of its provenance' {
        $hash = 'a' * 64
        $envelope = New-MessageEnvelope -Code 'pool.assignment_blocked' -Rendered @{
            text = 'Wording may change'
            messageKey = 'pool.pool_project_denied'
            locale = 'en-US'
            catalogHash = $hash
        }
        Assert-False ([bool]$envelope.rendered.authoritative) 'rendered prose claims to be authoritative'
        Assert-StringEqual -Expected $hash -Actual $envelope.rendered.catalogHash 'rendered prose names no catalog set'
        Assert-True (Test-MessageEnvelope -Envelope $envelope) 'derived provenance does not satisfy the schema'
    }

    It 'never permits credential-shaped arguments' {
        Assert-Throw {
            New-MessageEnvelope -Code 'pool.assignment_blocked' -Arguments @{ apiToken = 'secret' } -ArgumentTypes @{ apiToken = 'text' }
        } 'secrets do not belong' 'structured arguments made a secret easier to persist'
    }
}

Describe 'third-party detail is untrusted, bounded and redacted' {

    It 'redacts explicit and recognizable secrets before persistence' {
        $secret = 'ghp_123456'
        $text = "tool failed: Authorization: Bearer $secret token=another password=hunter2 named=$secret"
        $envelope = New-MessageEnvelope -Code 'repository.access_denied' -DetailText $text -DetailSource 'git.stderr' -Secret $secret
        Assert-False ($envelope.detail.text.Contains($secret)) 'an explicit secret survived'
        Assert-False ($envelope.detail.text.Contains('another')) 'a token assignment survived'
        Assert-False ($envelope.detail.text.Contains('hunter2')) 'a password assignment survived'
        Assert-StringEqual -Expected 'git.stderr' -Actual $envelope.detail.source 'the untrusted source was lost'
    }

    It 'redacts an explicit secret without treating case as protection' {
        $redaction = $script:Fixture.redaction
        $detail = Protect-MessageDetail -Text $redaction.mixedCaseText -Source 'tool.stderr' `
            -Secret $redaction.explicitSecret
        Assert-True ($detail.text.Contains('[REDACTED]')) 'the mixed-case occurrence was not replaced'
        Assert-True ($detail.text.IndexOf([string]$redaction.explicitSecret,
                [StringComparison]::OrdinalIgnoreCase) -lt 0) 'the explicit secret survived with different case'
    }

    It 'removes terminal controls and bounds detail without touching identity' {
        $hostile = ([string][char]0x1b) + '[31m' + ('x' * 5000) + ' code=other.condition'
        $envelope = New-MessageEnvelope -Code 'repository.access_denied' -DetailText $hostile -DetailSource 'git.stderr'
        Assert-True ($envelope.detail.text.Length -le [int]$script:Fixture.maxDetailLength) 'detail exceeded its wire bound'
        Assert-False ($envelope.detail.text.Contains([string][char]0x1b)) 'a terminal control survived'
        Assert-StringEqual -Expected 'repository.access_denied' -Actual $envelope.code 'detail selected a different code'
    }

    It 'refuses an unstable detail-source label' {
        Assert-Throw {
            New-MessageEnvelope -Code 'repository.access_denied' -DetailText 'no' -DetailSource '../stderr'
        } 'stable source token' 'an untrusted source became a path-like token'
    }

    It 'rejects unsafe detail arriving inside direct and nested v1 wire envelopes' {
        foreach ($case in @($script:Fixture.redaction.unsafeDirectDetails)) {
            $secret = @($case.secrets | ForEach-Object { [string]$_ })
            $message = [ordered]@{
                schema = 'yuruna.message/v1'
                code = 'repository.access_denied'
                args = [ordered]@{}
                detail = [ordered]@{ text = [string]$case.text; source = 'tool.stderr' }
            }
            Assert-False (Test-MessageEnvelope -Envelope $message -SchemaPath $script:SchemaPath -Secret $secret) `
                "direct validation accepted '$($case.name)'"
            foreach ($record in @($message, [ordered]@{ message = $message })) {
                Assert-Throw { ConvertTo-MessageEnvelope -InputObject $record -Secret $secret } 'envelope is invalid' `
                    "the direct/nested reader accepted '$($case.name)'"
            }
        }
    }
}

Describe 'the named N/N-1 migration is bidirectional and finite' {

    It 'lets a new consumer read each legacy producer family' {
        $cases = @(
            @{ Input = @{ failureClass = 'ssh_timeout'; errorMessage = 'timed out' }; Code = 'failure.ssh_timeout' }
            @{ Input = @{ event = 'step_start'; reason = 'begin' }; Code = 'step.start' }
            @{ Input = @{ diagnosticClass = 'network_timeout'; errorMessage = 'down' }; Code = 'diagnostic.network_timeout' }
            @{ Input = @{ reason = 'old free text' }; Code = 'legacy.condition' }
        )
        foreach ($case in $cases) {
            $got = ConvertTo-MessageEnvelope -InputObject $case.Input
            Assert-StringEqual -Expected $case.Code -Actual $got.code "legacy conversion for $($case.Code)"
            Assert-True (Test-MessageEnvelope -Envelope $got) "legacy conversion for $($case.Code) is not v1"
        }
    }

    It 'lets an old consumer read a new producer during the window' {
        $envelope = New-MessageEnvelope -Code 'failure.ssh_timeout' -DetailText 'timed out' -DetailSource 'ssh.stderr'
        $record = ConvertTo-MessageCompatibilityRecord -Envelope $envelope
        Assert-StringEqual -Expected 'ssh_timeout' -Actual $record.failureClass 'the old router lost its class'
        Assert-StringEqual -Expected 'timed out' -Actual $record.errorMessage 'the old renderer lost its detail'
        Assert-StringEqual -Expected 'yuruna.message/v1' -Actual $record.message.schema 'the new consumer lost its envelope'
    }

    It 'prefers the v1 envelope when a dual-written record carries both' {
        $envelope = New-MessageEnvelope -Code 'failure.ssh_timeout'
        $record = [ordered]@{ message = $envelope; failureClass = 'different_legacy_value' }
        $got = ConvertTo-MessageEnvelope -InputObject $record
        Assert-StringEqual -Expected 'failure.ssh_timeout' -Actual $got.code 'legacy prose/identity overrode v1'
    }

    It 'dual-reads records after normal JSON parsing, not only in-memory hashtables' {
        $legacy = ConvertFrom-Json -InputObject '{"failureClass":"ssh_timeout","errorMessage":"timed out"}'
        $fromLegacy = ConvertTo-MessageEnvelope -InputObject $legacy
        Assert-StringEqual -Expected 'failure.ssh_timeout' -Actual $fromLegacy.code `
            'a normal JSON object could not enter the legacy compatibility boundary'

        $wire = '{"message":{"schema":"yuruna.message/v1","code":"failure.ssh_timeout","args":{}},"failureClass":"different"}'
        $fromDual = ConvertTo-MessageEnvelope -InputObject (ConvertFrom-Json -InputObject $wire)
        Assert-StringEqual -Expected 'failure.ssh_timeout' -Actual $fromDual.code `
            'a parsed dual-write record stopped preferring its v1 identity'
    }

    It 'pins a release and calendar date for deleting every legacy field' {
        $policy = Get-MessageMigrationPolicy
        Assert-StringEqual -Expected ([string]$script:Fixture.legacyReadUntilRelease) -Actual ([string]$policy.legacyReadUntilRelease) 'the runtime and fixture disagree on the removal release'
        Assert-StringEqual -Expected ([string]$script:Fixture.legacyReadUntilDate) -Actual ([string]$policy.legacyReadUntilDate) 'the runtime and fixture disagree on the removal date'
        Assert-True ([DateTime]$policy.legacyReadUntilDate -gt [DateTime]'2026-09-03') 'the migration date is already expired'
        foreach ($field in @('failureClass', 'reason', 'errorMessage', 'event', 'diagnosticClass')) {
            Assert-True (@($policy.legacyFields) -contains $field) "'$field' has no declared compatibility window"
        }
    }
}
