<#PSScriptInfo
.VERSION 2026.11.23
.GUID 420efd99-6729-46c3-ac64-111d2e331431
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence secret pester
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
    Pester guard on the secret filter in Test.SequenceSecret.psm1 and its hooks
    in the variable, action, failure-state and engine modules.
.DESCRIPTION
    A workload authoring session returns and writes text that came from a
    guest screen, a failure record or a step it ran; a password the session
    knows must never appear in any of it. The cases pin which values are
    registered (a variable named like a secret, an authentication extension
    result, a value a sensitive step uses, but never the argument of an
    extension call), every spelling the filter replaces, the OCR-tolerant mask,
    that a failure record keeps its shape when filtered, that the engine hooks
    add nothing to the output stream, and that the stores survive a forced
    re-import of the module.

    No case needs a VM or a real clock. Fixture verbs run through
    Invoke-SequenceActionHandler directly.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceEngine.psm1') -Force -Global -DisableNameChecking
    # The planner's load imports the engine again with -Force; loading it now
    # keeps a later call from replacing the modules a mock below is set in.
    Import-Module (Join-Path $PSScriptRoot 'Test.SequencePlanner.psm1') -Global -DisableNameChecking
    $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime'
    $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'log'
    $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR, $env:YURUNA_LOG_DIR -Force

    function Get-SecretFixtureRecordText {
        <#
        .SYNOPSIS
            The JSON of a failure record's file and of its event, timestamps blanked.
        .DESCRIPTION
            The event is a plain hashtable, whose copy may enumerate its keys in
            another order, so it is compared through its keys sorted ordinally.
        #>
        param([Parameter(Mandatory)][hashtable]$Record)
        $file = $Record.File
        if ($file.Contains('timestamp')) { $file['timestamp'] = '' }
        $sortedEvent = [ordered]@{}
        $keys = [string[]]@($Record.Event.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $sortedEvent[$key] = $Record.Event[$key] }
        if ($sortedEvent.Contains('timestamp')) { $sortedEvent['timestamp'] = '' }
        return @{
            File  = ($file | ConvertTo-Json -Depth 12)
            Event = ($sortedEvent | ConvertTo-Json -Depth 12)
        }
    }

    function Get-SecretFixtureFailureRecord {
        <#
        .SYNOPSIS
            Builds a step failure record from the live failure slots.
        #>
        return (New-SequenceFailureRecord -Reason step -VMName 'never-a-real-vm' -GuestKey 'guest.fixture' -HostType 'host.fixture' -SequencePath (Join-Path $TestDrive 'fixture.yml') -LogDir $env:YURUNA_LOG_DIR -TotalSteps 1)
    }
}

AfterAll {
    Disable-SequenceSecretFilter
    Clear-SequenceSecret
    Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
}

Describe 'the secret filter registers and masks values' {
    BeforeEach {
        Clear-SequenceSecret
        Enable-SequenceSecretFilter
    }

    It 'registers nothing while the filter is disabled' {
        Disable-SequenceSecretFilter
        Assert-False (Register-SequenceSecret -Value 'disabled-1') 'a disabled filter accepted a value'
        Assert-Equal 0 (Get-SequenceSecretStat).count
    }

    It 'skips a value shorter than four characters and counts it' {
        Assert-False (Register-SequenceSecret -Value 'ab') 'a two-character value was registered'
        $stat = Get-SequenceSecretStat
        Assert-Equal 1 $stat.shortSkipped
        Assert-Equal 0 $stat.count
    }

    It 'replaces the longer of two overlapping values first' {
        Assert-True (Register-SequenceSecret -Value 'abcd')
        Assert-True (Register-SequenceSecret -Value 'abcdef')
        Assert-StringEqual 'one *** two ***' (Protect-SequenceSecretText -Text 'one abcdef two abcd')
    }

    It 'replaces the JSON, URL and quoted spellings of a value' {
        $value = 'aB3$x"q\z&<1>' + "'"
        Assert-True (Register-SequenceSecret -Value $value)
        $json = ConvertTo-Json -InputObject $value -Compress
        $url = [uri]::EscapeDataString($value)
        $quoted = $value.Replace("'", "''")
        foreach ($spelling in @($json, $url, $quoted)) {
            $filtered = Protect-SequenceSecretText -Text "before $spelling after"
            Assert-False ($filtered.Contains($value, [StringComparison]::Ordinal)) "the value survived in '$filtered'"
            Assert-False ($filtered.Contains($json.Trim('"'), [StringComparison]::Ordinal)) "the JSON spelling survived in '$filtered'"
            Assert-False ($filtered.Contains($url, [StringComparison]::Ordinal)) "the URL spelling survived in '$filtered'"
            Assert-False ($filtered.Contains($quoted, [StringComparison]::Ordinal)) "the quoted spelling survived in '$filtered'"
        }
    }

    It 'matches case exactly' {
        Assert-True (Register-SequenceSecret -Value 'Secret9!')
        Assert-StringEqual 'a secret9! b' (Protect-SequenceSecretText -Text 'a secret9! b')
        Assert-StringEqual 'a *** b' (Protect-SequenceSecretText -Text 'a Secret9! b')
    }

    It 'masks a line an OCR engine misread only in the tolerant mode' {
        Assert-True (Register-SequenceSecret -Value 'S3cr3t-Value!9')
        $text = "first line`nu1 login: 53cr3t-VaIue!g`nlast line"
        Assert-StringEqual $text (Protect-SequenceSecretText -Text $text)
        Assert-StringEqual "first line`n***`nlast line" (Protect-SequenceSecretText -Text $text -OcrTolerant)
    }

    It 'returns the object itself when no value is registered' {
        $object = [ordered]@{ a = 'one'; b = @(1, 2) }
        Assert-True ([object]::ReferenceEquals($object, (Protect-SequenceSecretObject -InputObject $object)))
    }

    It 'keeps the shape of a failure record' {
        Assert-True (Register-SequenceSecret -Value 'zz-not-in-the-record-zz')
        $state = Get-SequenceFailureState
        $texts = foreach ($enabled in @($true, $false)) {
            Reset-SequenceFailureSlot -Lifetime sequence -State $state
            $state.WaitForTextPatternsSought = [string[]]@()
            $state.WaitForTextFreshWindowNearMiss = [string[]]@('one')
            $state.WaitForTextKernelStallEnd = [pscustomobject]@{ Nested = @{ a = $null } }
            if ($enabled) { Enable-SequenceSecretFilter } else { Disable-SequenceSecretFilter }
            $record = Get-SecretFixtureFailureRecord
            Assert-True ($record.Event -is [hashtable]) 'the event is no longer a hashtable'
            Assert-True ($record.File.context -is [System.Collections.Specialized.OrderedDictionary]) 'the record context is no longer ordered'
            Get-SecretFixtureRecordText -Record $record
        }
        Assert-StringEqual $texts[1].File $texts[0].File 'the filtered record file changed shape'
        Assert-StringEqual $texts[1].Event $texts[0].Event 'the filtered record event changed shape'
    }

    It 'filters the record and its event when a value is registered' {
        $value = 'fixture-ocr-secret-7'
        Assert-True (Register-SequenceSecret -Value $value)
        $state = Get-SequenceFailureState
        Reset-SequenceFailureSlot -Lifetime sequence -State $state
        $state.WaitForTextOcrTail = "login: user`nPassword: $value`n$ "
        $record = Get-SecretFixtureFailureRecord
        $fileJson = $record.File | ConvertTo-Json -Depth 12
        $eventJson = $record.Event | ConvertTo-Json -Depth 12
        Assert-False ($fileJson.Contains($value, [StringComparison]::Ordinal)) 'the record file holds the value'
        Assert-False ($eventJson.Contains($value, [StringComparison]::Ordinal)) 'the record event holds the value'
        Reset-SequenceFailureSlot -Lifetime sequence -State $state
    }

    It 'hands a new value to the mask sink once and counts a refusal' {
        $calls = [Collections.Generic.List[string]]::new()
        $stub = { param([string[]]$Value) foreach ($item in $Value) { $calls.Add($item) }; $false }.GetNewClosure()
        $null = New-Item -Path function:global:Send-WorkloadMask -Value $stub -Force
        try {
            Assert-True (Register-SequenceSecret -Value 'zeta-1')
            Assert-True (Register-SequenceSecret -Value 'zeta-1')
            Assert-Equal 1 $calls.Count
            Assert-StringEqual 'zeta-1' $calls[0]
            Assert-Equal 1 (Get-SequenceSecretStat).maskFailed
        } finally {
            Remove-Item -LiteralPath function:\Send-WorkloadMask
        }
        Assert-True (Register-SequenceSecret -Value 'zeta-2') 'registration needs no mask sink'
        Assert-Equal 1 (Get-SequenceSecretStat).maskFailed
    }

    It 'keeps its values across a forced re-import of the module' {
        Assert-True (Register-SequenceSecret -Value 'survives-1')
        Import-Module (Join-Path $PSScriptRoot 'Test.SequenceSecret.psm1') -Force -Global -DisableNameChecking
        Assert-True (Test-SequenceSecretFilterEnabled) 'the re-import turned the filter off'
        Assert-True (Test-SequenceSecretText -Text 'x survives-1 y') 'the re-import forgot a value'
        Assert-Equal 1 (Get-SequenceSecretStat).count
    }

    It 'uses the name pattern Protect-GuestEvidenceText uses' {
        $pattern = & (Get-Module Test.SequenceSecret) { $script:SecretNamePattern }
        $diagnostic = Get-YurunaTestSourceText -Path (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1')
        Assert-True ($diagnostic.Contains("'$pattern'", [StringComparison]::Ordinal)) "Test.Diagnostic.psm1 no longer holds '$pattern'"
    }
}

Describe 'the engine hooks register secrets' {
    BeforeAll {
        $script:HookAnswers = [Collections.Generic.List[object]]::new()
        $answers = $script:HookAnswers
        Register-SequenceAction -Name secretHookFixture -ReplaySafety observe -Handler {
            param($context)
            $answers.Add((Test-SequenceSecretText -Text 'fixture-pass-2'))
            $expanded = Expand-Variable -Text $context.Step.text -Variables $context.Vars
            $answers.Add((Test-SequenceSecretText -Text 'fixture-digest-1'))
            $answers.Add((Test-SequenceSecretText -Text 'fixture-pass-1'))
            $answers.Add((Test-SequenceSecretText -Text 'yuuser26'))
            $answers.Add($expanded)
            return $true
        }.GetNewClosure()
        Register-SequenceAction -Name secretThrowFixture -ReplaySafety observe -Handler {
            param($context)
            throw "fixture handler failure in $($context.Step.action)"
        }
    }
    BeforeEach {
        Clear-SequenceSecret
        Enable-SequenceSecretFilter
        $script:HookAnswers.Clear()
    }

    It 'registers a variable named like a secret when the scope is built' {
        $null = New-SequenceVariableScope -VMName 'never-a-real-vm' -HostType 'host.fixture' -GuestKey 'guest.fixture' `
            -SequenceVariables ([ordered]@{ currentPassword = 'fixture-secret'; note = 'xxxx' }) -EffectiveVariables $null
        Assert-True (Test-SequenceSecretText -Text 'fixture-secret') 'the password variable was not registered'
        Assert-False (Test-SequenceSecretText -Text 'xxxx') 'a variable not named like a secret was registered'
        Assert-Equal 1 (Get-SequenceSecretStat).count
    }

    It 'registers an authentication extension result and leaves another area alone' {
        Mock Invoke-ExtensionExpression -ModuleName Test.SequenceVariable { 'fixture-value-1' }
        $null = Expand-Variable -Text '${ext:authentication.GetPassword(u)}' -Variables @{}
        Assert-True (Test-SequenceSecretText -Text 'fixture-value-1') 'the authentication result was not registered'
        Clear-SequenceSecret
        $null = Expand-Variable -Text '${ext:digest.GetFileSha256(f)}' -Variables @{}
        Assert-Equal 0 (Get-SequenceSecretStat).count 'a digest result outside a sensitive step was registered'
    }

    It 'registers what a sensitive step uses before its handler runs' {
        Mock Invoke-ExtensionExpression -ModuleName Test.SequenceVariable { 'fixture-digest-1' }
        $vars = @{ pass = 'fixture-pass-2' }
        $null = Invoke-SequenceActionHandler -Name secretHookFixture -Context @{ Step = @{ action = 'secretHookFixture'; sensitive = $true; text = '${pass}' }; Vars = $vars }
        Assert-True $script:HookAnswers[0] 'the variable of a sensitive step was not registered before its handler ran'
        $script:HookAnswers.Clear()
        $null = Invoke-SequenceActionHandler -Name secretHookFixture -Context @{ Step = @{ action = 'secretHookFixture'; sensitive = $true; text = '${ext:digest.GetFileSha256(f)}' }; Vars = $vars }
        Assert-True $script:HookAnswers[1] 'an extension result computed inside a sensitive step was not registered'
        Clear-SequenceSecret
        $script:HookAnswers.Clear()
        $null = Invoke-SequenceActionHandler -Name secretHookFixture -Context @{ Step = @{ action = 'secretHookFixture'; text = '${pass}' }; Vars = $vars }
        Assert-False $script:HookAnswers[0] 'a step without sensitive registered its variable'
        $script:HookAnswers.Clear()
        $null = Invoke-SequenceActionHandler -Name secretHookFixture -Context @{ Step = @{ action = 'secretHookFixture'; text = '${ext:digest.GetFileSha256(f)}' }; Vars = $vars }
        Assert-False $script:HookAnswers[1] 'a step without sensitive registered an extension result'
    }

    It 'returns the depth to zero when a sensitive handler throws' {
        $threw = $false
        try {
            $null = Invoke-SequenceActionHandler -Name secretThrowFixture -Context @{ Step = @{ action = 'secretThrowFixture'; sensitive = $true; text = 'x' }; Vars = @{} }
        } catch {
            $threw = $true
        }
        Assert-True $threw 'the fixture handler did not throw'
        Register-SequenceSecretFromExtension -Area 'digest' -Value 'after-throw-1'
        Assert-False (Test-SequenceSecretText -Text 'after-throw-1') 'the step depth stayed raised after a throw'
    }

    It 'writes nothing to the output stream from the engine hooks' {
        Mock Invoke-ExtensionExpression -ModuleName Test.SequenceVariable { 'fixture-value-1' }
        foreach ($enabled in @($true, $false)) {
            if (-not $enabled) { Disable-SequenceSecretFilter }
            Assert-Equal 0 @(Register-SequenceSecretVariable -Variables @{ dbPassword = 'abcd-1' }).Count
            Assert-Equal 0 @(Register-SequenceSecretFromExtension -Area authentication -Value 'abcd-2').Count
            Assert-Equal 0 @(Enter-SequenceSecretStep -Step @{ text = 'x' } -Variables @{}).Count
            Assert-Equal 0 @(Exit-SequenceSecretStep).Count
            $expanded = Expand-Variable '${ext:authentication.GetPassword(u)}' @{}
            Assert-True ([string]::Equals('fixture-value-1', $expanded, [StringComparison]::Ordinal)) "the expansion was '$expanded'"
        }
    }

    It 'does not register the argument of an extension call in a sensitive step' {
        Mock Invoke-ExtensionExpression -ModuleName Test.SequenceVariable { 'fixture-pass-1' }
        $null = Invoke-SequenceActionHandler -Name secretHookFixture -Context @{
            Step = @{ action = 'secretHookFixture'; sensitive = $true; text = '${ext:authentication.GetPassword(${username})}' }
            Vars = @{ username = 'yuuser26'; loginUser = 'yuuser26' }
        }
        Assert-True $script:HookAnswers[2] 'the extension result was not registered'
        Assert-False $script:HookAnswers[3] 'the argument of the extension call was registered'
    }
}
