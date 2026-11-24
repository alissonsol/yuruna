<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42281001-28b7-4521-9fc8-c1a9a99192a6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence phrase pester
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
    Pester guard on step sentences in Test.StepPhrase.psm1: the tokenizer, the
    phrase libraries, matching, slot values, labels and the reverse writer.
.DESCRIPTION
    A sentence step is replaced by action steps when the sequence file is read,
    so a fault here runs the wrong steps or prints a secret with nothing else
    failing. The cases pin: the generated steps of every starter sentence
    against the checked-in table test/fixtures/step-phrase/starter.expected.json;
    the planner errors and their codes; that no label holds a secret value or an
    extension call the engine would run again; that the schema file and the
    reader refuse the same malformed libraries; and that the library caches see
    every edit while holding at most eight compiled libraries.

    Every case writes its fixture libraries into a fresh folder under $TestDrive.
    The framework library is test/sequences/_phrases.yml.
#>

BeforeDiscovery {
    $fixturePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'fixtures/step-phrase/starter.expected.json'
    $fixture = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json -AsHashtable -DateKind String
    $script:StarterCase = @(foreach ($row in $fixture.cases) {
        @{
            Sentence       = [string]$row.sentence
            Surface        = [string]$row.surface
            TimeoutSeconds = $(if ($row.ContainsKey('timeoutSeconds')) { [int]$row.timeoutSeconds } else { 0 })
            Description    = $(if ($row.ContainsKey('description')) { [string]$row.description } else { '' })
            Expected       = @($row.steps)
        }
    })
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CanonicalJson.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SequenceResolve.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.StepPhrase.psm1') -Force -DisableNameChecking
    Import-Module powershell-yaml -ErrorAction Stop

    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $sequenceSchema = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/schemas/sequence.schema.yml') | ConvertFrom-Yaml -Ordered
    $script:StepSchemaJson = [ordered]@{
        '$schema' = 'https://json-schema.org/draft/2020-12/schema'
        '$defs'   = $sequenceSchema['$defs']
        '$ref'    = '#/$defs/actionStep'
    } | ConvertTo-Json -Depth 32
    $script:PressKeyName = @(foreach ($branch in $sequenceSchema['$defs']['actionStep']['allOf']) {
        if ([string]$branch['if']['properties']['action']['const'] -ceq 'pressKey') { $branch['then']['properties']['name']['enum'] }
    })
    $script:PhraseSchemaJson = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/schemas/phrases.schema.yml') |
        ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
    $script:FrameworkLibraryPath = Join-Path $script:RepoRoot 'test/sequences/_phrases.yml'
    $fixturePath = Join-Path $script:RepoRoot 'test/fixtures/step-phrase/starter.expected.json'
    $script:FixtureCase = @((Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json -AsHashtable -DateKind String).cases)
    $script:Starter = Get-SequencePhraseLibrary
    $script:LoginSentence = 'login ${username} with password ${ext:authentication.GetPassword(${username})}'
    $script:CaseNumber = 0

    function New-PhraseCaseDir {
        <#
        .SYNOPSIS
            A fresh folder for one case, so no path-keyed cache serves an earlier case.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a test folder under TestDrive.')]
        [CmdletBinding()]
        [OutputType([string])]
        param()
        $script:CaseNumber++
        $dir = Join-Path $TestDrive ('phrase{0:D3}' -f $script:CaseNumber)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    function Write-PhraseText {
        <#
        .SYNOPSIS
            Write one fixture file, creating its folder.
        #>
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllText($Path, $Content)
    }

    function Read-FixtureLibrary {
        <#
        .SYNOPSIS
            Write a fixture library into a fresh folder and load it alone.
        #>
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][string]$Content)
        $path = Join-Path (New-PhraseCaseDir) '_phrases.yml'
        Write-PhraseText -Path $path -Content $Content
        return (Get-StepPhraseLibrary -Source @(@{ Path = $path; Tier = 'framework' }))
    }

    function Get-CaughtException {
        <#
        .SYNOPSIS
            The exception a script block throws; fails the case when it throws none.
        #>
        [CmdletBinding()]
        [OutputType([Exception])]
        param([Parameter(Mandatory)][scriptblock]$Script)
        try { & $Script } catch { return $_.Exception }
        throw 'Expected a throw.'
    }

    function Get-StepWithoutLabel {
        <#
        .SYNOPSIS
            Canonical JSON of generated steps without their label members.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][object[]]$Step)
        $copy = @(foreach ($item in $Step) {
            $clone = [ordered]@{}
            foreach ($key in $item.Keys) { if ($key -cnotin 'description', 'fromStep') { $clone[$key] = $item[$key] } }
            $clone
        })
        return (ConvertTo-CanonicalApprovalJson -Value $copy)
    }
}

Describe 'a sentence is read into tokens' {
    It 'splits <Sentence> into its tokens' -TestCases @(
        @{ Sentence = 'x ${ext:a.B(${x}, ${y})}'; Expected = @(@('word', 'x', $false), @('word', '${ext:a.B(${x}, ${y})}', $true)) }
        @{ Sentence = '${username}@${hostname}:~$'; Expected = @(, @('word', '${username}@${hostname}:~$', $true)) }
        @{ Sentence = "type it's"; Expected = @(@('word', 'type', $false), @('word', "it's", $false)) }
        @{ Sentence = "'a''b' ""c""""d"""; Expected = @(@('quoted', "a'b", $false), @('quoted', 'c"d', $false)) }
        @{ Sentence = 'a $${x}'; Expected = @(@('word', 'a', $false), @('word', '$${x}', $false)) }
        @{ Sentence = 'a $$${x}'; Expected = @(@('word', 'a', $false), @('word', '$$${x}', $true)) }
        @{ Sentence = "a`tb`nc"; Expected = @(@('word', 'a', $false), @('word', 'b', $false), @('word', 'c', $false)) }
        @{ Sentence = "'C:\temp\new'"; Expected = @(, @('quoted', 'C:\temp\new', $false)) }
        @{ Sentence = "'`$1 <label> a: b # c'"; Expected = @(, @('quoted', '$1 <label> a: b # c', $false)) }
        @{ Sentence = "type ''"; Expected = @(@('word', 'type', $false), @('quoted', '', $false)) }
    ) {
        $tokens = @(ConvertTo-StepPhraseToken -Sentence $Sentence)
        Assert-Equal -Expected $Expected.Count -Actual $tokens.Count -Because 'token count'
        for ($at = 0; $at -lt $Expected.Count; $at++) {
            Assert-StringEqual -Expected $Expected[$at][0] -Actual $tokens[$at].Kind -Because "kind of token $at"
            Assert-True ($tokens[$at].Value -ceq $Expected[$at][1]) "value of token $at is '$($tokens[$at].Value)'"
            Assert-Equal -Expected $Expected[$at][2] -Actual $tokens[$at].HasExpression -Because "HasExpression of token $at"
        }
    }

    It 'rejects <Sentence> with <Reason> at character <Position>' -TestCases @(
        @{ Sentence = "'unterminated"; Reason = 'unterminated-quote'; Position = 1 }
        @{ Sentence = "'a'b"; Reason = 'text-after-quote'; Position = 4 }
        @{ Sentence = '${open'; Reason = 'unterminated-expression'; Position = 1 }
        @{ Sentence = '${a(b}'; Reason = 'unbalanced-expression'; Position = 6 }
        @{ Sentence = '${a)}'; Reason = 'unbalanced-expression'; Position = 4 }
        @{ Sentence = ''; Reason = 'empty'; Position = 1 }
        @{ Sentence = '   '; Reason = 'empty'; Position = 1 }
        @{ Sentence = ('x' * 2001); Reason = 'too-long'; Position = 2001 }
    ) {
        $caught = Get-CaughtException { $null = @(ConvertTo-StepPhraseToken -Sentence $Sentence -Location 'seq.yml: workload[1]') }
        Assert-StringEqual -Expected 'runner.step_phrase_malformed' -Actual $caught.Data['YurunaMessageCode']
        Assert-True $caught.Message.Contains("($Reason)") "the message names the reason: $($caught.Message)"
        Assert-True $caught.Message.Contains(" $Position.") "the message names the position: $($caught.Message)"
        if (-not [string]::IsNullOrWhiteSpace($Sentence)) {
            Assert-False $caught.Message.Contains($Sentence) 'the message never repeats the sentence'
        }
    }
}

Describe 'the starter vocabulary resolves to the checked-in steps' {
    It 'resolves "<Sentence>" to the checked-in steps' -TestCases $script:StarterCase {
        $resolveArgument = @{ Sentence = $Sentence; Surface = $Surface; Library = $script:Starter; TimeoutSeconds = $TimeoutSeconds; Description = $Description }
        $actual = @(Resolve-StepPhrase @resolveArgument)
        Assert-StringEqual -Expected (ConvertTo-CanonicalApprovalJson -Value $Expected) -Actual (ConvertTo-CanonicalApprovalJson -Value $actual)
    }

    It 'has a checked-in case for every phrase and surface of the framework library' {
        $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $script:FixtureCase) {
            $found = Find-StepPhrase -Sentence $row.sentence -Library $script:Starter
            [void]$covered.Add("$($found.Phrase.Id)|$($row.surface)")
        }
        $findings = @(foreach ($phrase in $script:Starter.Phrases) {
            foreach ($surfaceName in $phrase.Surfaces.Keys) {
                if (-not $covered.Contains("$($phrase.Id)|$surfaceName")) { "$($phrase.Id) ($surfaceName) has no case in starter.expected.json" }
            }
        })
        Assert-NoFinding $findings 'every phrase and surface of the vocabulary shows its steps in a reviewed table'
    }

    It 'generates steps that satisfy the step schema' {
        $findings = @(foreach ($row in $script:FixtureCase) {
            $resolveArgument = @{ Sentence = $row.sentence; Surface = $row.surface; Library = $script:Starter }
            if ($row.ContainsKey('timeoutSeconds')) { $resolveArgument.TimeoutSeconds = [int]$row.timeoutSeconds }
            if ($row.ContainsKey('description')) { $resolveArgument.Description = [string]$row.description }
            foreach ($step in @(Resolve-StepPhrase @resolveArgument)) {
                if (-not (Test-Json -Json ($step | ConvertTo-Json -Depth 32) -Schema $script:StepSchemaJson -ErrorAction SilentlyContinue)) {
                    "$($row.sentence): '$($step.action)' is not a valid step"
                }
            }
        })
        Assert-NoFinding $findings 'a generated step is an ordinary action step'
    }
}

Describe 'a sentence matches one phrase' {
    It 'matches literal words without regard to case or spacing' {
        $plain = @(Resolve-StepPhrase -Sentence 'click button Next' -Surface screen -Library $script:Starter)
        $spaced = @(Resolve-StepPhrase -Sentence '  CLICK   button   Next ' -Surface screen -Library $script:Starter)
        Assert-StringEqual -Expected (Get-StepWithoutLabel -Step $plain) -Actual (Get-StepWithoutLabel -Step $spaced)
    }

    It 'does not let a quoted string stand for a literal word' {
        foreach ($sentence in @("'click' Next", 'click "button" Next')) {
            $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence $sentence -Surface screen -Library $script:Starter) }
            Assert-StringEqual -Expected 'runner.step_phrase_no_match' -Actual $caught.Data['YurunaMessageCode'] -Because $sentence
        }
    }

    It 'takes one token for a slot' {
        $bare = @(Resolve-StepPhrase -Sentence 'click button' -Surface screen -Library $script:Starter)
        Assert-True ($bare[0].label -ceq 'button') "label is '$($bare[0].label)'"
        Assert-False $bare[0].Contains('match') 'the click phrase writes no match'
        $quoted = @(Resolve-StepPhrase -Sentence 'click "button Next"' -Surface screen -Library $script:Starter)
        Assert-True ($quoted[0].label -ceq 'button Next') "label is '$($quoted[0].label)'"
        $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence 'type a b' -Surface screen -Library $script:Starter) }
        Assert-StringEqual -Expected 'runner.step_phrase_no_match' -Actual $caught.Data['YurunaMessageCode']
    }

    It 'keeps slot text unchanged (<Value>)' -TestCases @(
        @{ Value = 'a  b' }, @{ Value = "It's" }, @{ Value = 'C:\x' }, @{ Value = '$1' }, @{ Value = '$&' },
        @{ Value = 'a: b # c' }, @{ Value = '<user>' }
    ) {
        $written = "'" + $Value.Replace("'", "''") + "'"
        $steps = @(Resolve-StepPhrase -Sentence "type $written and press Enter" -Surface screen -Library $script:Starter)
        Assert-Equal -Expected 1 -Actual $steps.Count
        Assert-True ($steps[0].text -ceq $Value) "text is '$($steps[0].text)'"
    }

    It 'names the three nearest sentences and masks unknown words' {
        $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence 'login admin with pasword hunter2' -Surface screen -Library $script:Starter) }
        Assert-StringEqual -Expected 'runner.step_phrase_no_match' -Actual $caught.Data['YurunaMessageCode']
        Assert-True $caught.Message.Contains('login *** with *** ***') "shape: $($caught.Message)"
        Assert-True $caught.Message.Contains('login <user> with password <password:secret>') "nearest: $($caught.Message)"
        Assert-False $caught.Message.Contains('admin') 'an unknown word is not echoed'
        Assert-False $caught.Message.Contains('hunter2') 'a value is not echoed'
    }

    It 'fails without a library' {
        $empty = Get-StepPhraseLibrary -Source @()
        $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence 'press Enter' -Surface screen -Library $empty) }
        Assert-StringEqual -Expected 'runner.step_phrase_no_library' -Actual $caught.Data['YurunaMessageCode']
    }

    It 'names the surfaces a phrase has' {
        $library = Read-FixtureLibrary -Content @'
phrases:
  greet:
    sentence: "greet <name>"
    screen:
      - action: inputTextAndEnter
        text: "hello <name>"
'@
        $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence 'greet Ann' -Surface page -Library $library) }
        Assert-StringEqual -Expected 'runner.step_phrase_surface_missing' -Actual $caught.Data['YurunaMessageCode']
        Assert-True $caught.Message.Contains('screen') "the message names the surface the phrase has: $($caught.Message)"
    }

    It 'resolves a sentence twice to equal steps that share no object and leaves the library unchanged' {
        $before = ConvertTo-CanonicalApprovalJson -Value $script:Starter
        $first = @(Resolve-StepPhrase -Sentence $script:LoginSentence -Surface screen -Library $script:Starter)
        $second = @(Resolve-StepPhrase -Sentence $script:LoginSentence -Surface screen -Library $script:Starter)
        $after = ConvertTo-CanonicalApprovalJson -Value $script:Starter
        Assert-StringEqual -Expected (ConvertTo-CanonicalApprovalJson -Value $first) -Actual (ConvertTo-CanonicalApprovalJson -Value $second)
        $templates = @(foreach ($phrase in $script:Starter.Phrases) { foreach ($surfaceName in $phrase.Surfaces.Keys) { @($phrase.Surfaces[$surfaceName]) } })
        foreach ($step in $first) {
            foreach ($other in @($second) + $templates) {
                Assert-False ([object]::ReferenceEquals($step, $other)) 'a generated step is a new object'
            }
        }
        Assert-StringEqual -Expected $before -Actual $after -Because 'resolving never changes the library'
    }

    It 'lists exactly three nearest sentences, in the same order on every call' {
        $library = Read-FixtureLibrary -Content @'
phrases:
  alpha:
    sentence: "alpha one <x>"
    screen:
      - action: inputText
        text: "<x>"
  bravo:
    sentence: "bravo two <x>"
    screen:
      - action: inputText
        text: "<x>"
  charlie:
    sentence: "charlie three <x>"
    screen:
      - action: inputText
        text: "<x>"
  delta:
    sentence: "delta four <x>"
    screen:
      - action: inputText
        text: "<x>"
  echo:
    sentence: "echo five <x>"
    screen:
      - action: inputText
        text: "<x>"
'@
        $messages = @(foreach ($attempt in 1, 2) {
            $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence 'zulu six seven' -Surface screen -Library $library) }
            Assert-StringEqual -Expected 'runner.step_phrase_no_match' -Actual $caught.Data['YurunaMessageCode'] -Because "attempt $attempt"
            $caught.Message
        })
        $named = @($library.Phrases | Where-Object { $messages[0].Contains($_.Sentence) })
        Assert-Equal -Expected 3 -Actual $named.Count -Because $messages[0]
        Assert-StringEqual -Expected $messages[0] -Actual $messages[1] -Because 'the nearest list is stable'
    }
}

Describe 'slot values are checked by their kind' {
    It 'accepts <Sentence>' -TestCases @(
        @{ Sentence = 'wait 0 seconds'; Field = 'seconds'; Expected = 0 }
        @{ Sentence = 'wait 999999999 seconds'; Field = 'seconds'; Expected = 999999999 }
        @{ Sentence = 'press f12'; Field = 'name'; Expected = 'F12' }
    ) {
        $steps = @(Resolve-StepPhrase -Sentence $Sentence -Surface screen -Library $script:Starter)
        $actual = $steps[0][$Field]
        if ($Expected -is [int]) {
            Assert-True ($actual -is [int]) "the value is a whole number, not $($actual.GetType().Name)"
            Assert-Equal -Expected $Expected -Actual $actual
        } else {
            Assert-True ($actual -ceq $Expected) "the key is spelled as the schema spells it: '$actual'"
        }
    }

    It 'rejects <Sentence> as <Code>' -TestCases @(
        @{ Sentence = 'wait five seconds'; Code = 'runner.step_phrase_slot_not_integer' }
        @{ Sentence = 'wait -1 seconds'; Code = 'runner.step_phrase_slot_not_integer' }
        @{ Sentence = 'wait 2.5 seconds'; Code = 'runner.step_phrase_slot_not_integer' }
        @{ Sentence = 'wait 05 seconds'; Code = 'runner.step_phrase_slot_not_integer' }
        @{ Sentence = 'wait ${n} seconds'; Code = 'runner.step_phrase_slot_not_integer' }
        @{ Sentence = "wait '5' seconds"; Code = 'runner.step_phrase_slot_not_integer' }
        @{ Sentence = 'wait 9999999999 seconds'; Code = 'runner.step_phrase_slot_not_integer' }
        @{ Sentence = 'press Home'; Code = 'runner.step_phrase_slot_not_key' }
        @{ Sentence = 'press ${k}'; Code = 'runner.step_phrase_slot_not_key' }
        @{ Sentence = "press 'Enter'"; Code = 'runner.step_phrase_slot_not_key' }
        @{ Sentence = "type '' and press Enter"; Code = 'runner.step_phrase_slot_empty' }
    ) {
        $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence $Sentence -Surface screen -Library $script:Starter) }
        Assert-StringEqual -Expected $Code -Actual $caught.Data['YurunaMessageCode']
    }

    It 'takes the key names and the timeout verbs from the schema' {
        Assert-True ($script:PressKeyName.Count -ge 20) 'the schema lists the pressKey names'
        foreach ($keyName in $script:PressKeyName) {
            $steps = @(Resolve-StepPhrase -Sentence "press $keyName" -Surface screen -Library $script:Starter)
            Assert-True ($steps[0].name -ceq $keyName) "press $keyName gives '$($steps[0].name)'"
        }
        $wait = @(Resolve-StepPhrase -Sentence 'wait for text ready' -Surface screen -Library $script:Starter -TimeoutSeconds 45)
        Assert-Equal -Expected 45 -Actual $wait[0].timeoutSeconds
        $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence 'press Enter' -Surface screen -Library $script:Starter -TimeoutSeconds 45) }
        Assert-StringEqual -Expected 'runner.step_phrase_timeout_unused' -Actual $caught.Data['YurunaMessageCode'] -Because 'pressKey takes no timeout'
    }
}

Describe 'labels never show a secret' {
    It 'shows a secret as *** and marks the step sensitive' {
        $steps = @(Resolve-StepPhrase -Sentence $script:LoginSentence -Surface screen -Library $script:Starter)
        foreach ($step in $steps) {
            Assert-False $step.description.Contains('GetPassword') "description: $($step.description)"
            Assert-False $step.fromStep.Contains('GetPassword') "fromStep: $($step.fromStep)"
            Assert-False $step.Contains('descriptionLocalized') 'no localized label was asked for'
        }
        Assert-True ($steps[1].sensitive -eq $true) 'the password step is sensitive'
        Assert-False $steps[0].Contains('sensitive') 'the user-name step is not'
    }

    It 'lets an author description win, masked' {
        $localized = [ordered]@{ 'pt-BR' = 'Entrar com hunter2 e ${ext:a.B()}'; 'zh-CN' = "hunter2 `u{767B}`u{5F55} `${ext:a.B()}" }
        $steps = @(Resolve-StepPhrase -Sentence "login admin with password 'hunter2'" -Surface screen -Library $script:Starter `
            -Description 'Log in with hunter2 and ${ext:a.B()}' -DescriptionLocalized $localized)
        Assert-Equal -Expected 2 -Actual $steps.Count
        for ($at = 0; $at -lt 2; $at++) {
            $suffix = " ($($at + 1)/2)"
            $labels = @($steps[$at].description) + @($steps[$at].descriptionLocalized.Values)
            Assert-Equal -Expected 3 -Actual $labels.Count
            foreach ($label in $labels) {
                Assert-False $label.Contains('hunter2') "label: $label"
                Assert-False $label.Contains('${ext:') "label: $label"
                Assert-True $label.Contains('***') "label: $label"
                Assert-True $label.EndsWith($suffix) "label: $label"
            }
        }
        Assert-True ($steps[0].description -ceq 'Log in with *** and *** (1/2)') "description: $($steps[0].description)"
    }

    It 'masks an extension call in an author description (<Text>)' -TestCases @(
        @{ Text = 'a ${ext:b.C(${d})} e'; Expected = 'a *** e' }
        @{ Text = 'a $${ext:b.C()} e'; Expected = 'a $${ext:b.C()} e' }
        @{ Text = 'a ${ext:b.C('; Expected = 'a ***' }
        @{ Text = 'a ${ext:b.C)} e'; Expected = 'a ***' }
    ) {
        $steps = @(Resolve-StepPhrase -Sentence 'type x and press Enter' -Surface screen -Library $script:Starter -Description $Text)
        Assert-True ($steps[0].description -ceq $Expected) "description: $($steps[0].description)"
    }

    It 'refuses a localized description without a description' {
        $caught = Get-CaughtException {
            $null = @(Resolve-StepPhrase -Sentence 'press Enter' -Surface screen -Library $script:Starter -DescriptionLocalized @{ 'pt-BR' = 'x' })
        }
        Assert-StringEqual -Expected 'runner.step_sentence_invalid' -Actual $caught.Data['YurunaMessageCode']
        Assert-True $caught.Message.Contains('without-description') $caught.Message
    }
}

Describe 'timeoutSeconds on a sentence' {
    It 'writes timeoutSeconds only where the verb takes one' {
        $login = @(Resolve-StepPhrase -Sentence $script:LoginSentence -Surface screen -Library $script:Starter -TimeoutSeconds 600)
        foreach ($step in $login) { Assert-Equal -Expected 600 -Actual $step.timeoutSeconds }
        $library = Read-FixtureLibrary -Content @'
phrases:
  nudge-and-wait:
    sentence: "nudge and wait"
    screen:
      - action: pressKey
        name: Enter
      - action: waitForText
        pattern: "ready"
'@
        $steps = @(Resolve-StepPhrase -Sentence 'nudge and wait' -Surface screen -Library $library -TimeoutSeconds 9)
        Assert-False $steps[0].Contains('timeoutSeconds') 'pressKey takes no timeout'
        Assert-Equal -Expected 9 -Actual $steps[1].timeoutSeconds
    }

    It 'rejects a timeout no step can take' {
        foreach ($sentence in 'press Enter', 'wait 5 seconds') {
            $caught = Get-CaughtException { $null = @(Resolve-StepPhrase -Sentence $sentence -Surface screen -Library $script:Starter -TimeoutSeconds 5) }
            Assert-StringEqual -Expected 'runner.step_phrase_timeout_unused' -Actual $caught.Data['YurunaMessageCode'] -Because $sentence
        }
    }
}

Describe 'phrase libraries' {
    It 'lets a project library add a phrase' {
        $dir = New-PhraseCaseDir
        $framework = Join-Path $dir 'framework/_phrases.yml'
        $project = Join-Path $dir 'project/_phrases.yml'
        Write-PhraseText -Path $framework -Content @'
phrases:
  press-key:
    sentence: "press <key:key>"
    screen:
      - action: pressKey
        name: "<key>"
'@
        Write-PhraseText -Path $project -Content @'
phrases:
  greet:
    sentence: "greet <name>"
    screen:
      - action: inputTextAndEnter
        text: "hello <name>"
'@
        $library = Get-StepPhraseLibrary -Source @(@{ Path = $framework; Tier = 'framework' }, @{ Path = $project; Tier = 'project' })
        $found = Find-StepPhrase -Sentence 'greet Ann' -Library $library
        Assert-StringEqual -Expected 'project' -Actual $found.Phrase.Tier
        $steps = @(Resolve-StepPhrase -Sentence 'greet Ann' -Surface screen -Library $library)
        Assert-True ($steps[0].text -ceq 'hello Ann') "text: $($steps[0].text)"
    }

    It 'rejects a second definition of a phrase id' {
        $dir = New-PhraseCaseDir
        $first = Join-Path $dir 'a/_phrases.yml'
        $second = Join-Path $dir 'b/_phrases.yml'
        Write-PhraseText -Path $first -Content "phrases:`n  greet:`n    sentence: ""greet <name>""`n    screen:`n      - action: inputText`n        text: ""<name>""`n"
        Write-PhraseText -Path $second -Content "phrases:`n  greet:`n    sentence: ""say hi to <name>""`n    screen:`n      - action: inputText`n        text: ""<name>""`n"
        $caught = Get-CaughtException { $null = Get-StepPhraseLibrary -Source @(@{ Path = $first; Tier = 'framework' }, @{ Path = $second; Tier = 'project' }) }
        Assert-StringEqual -Expected 'runner.step_phrase_duplicate_id' -Actual $caught.Data['YurunaMessageCode']
        Assert-True $caught.Message.Contains((Resolve-Path -LiteralPath $first).Path) $caught.Message
        Assert-True $caught.Message.Contains((Resolve-Path -LiteralPath $second).Path) $caught.Message
    }

    It 'rejects two phrases that can match one sentence (<Case>)' -TestCases @(
        @{ Case = 'the same shape with other slot names'; First = "  greet:`n    sentence: ""greet <name>""`n    screen:`n      - action: inputText`n        text: ""<name>""`n"
            Second = "  hello:`n    sentence: ""greet <who>""`n    screen:`n      - action: inputText`n        text: ""<who>""`n"; OneFile = $false; FirstId = 'greet'; SecondId = 'hello' }
        @{ Case = 'press Enter beside press key'; First = "  press-key:`n    sentence: ""press <key:key>""`n    screen:`n      - action: pressKey`n        name: ""<key>""`n"
            Second = "  press-enter:`n    sentence: ""press Enter""`n    screen:`n      - action: pressKey`n        name: Enter`n"; OneFile = $false; FirstId = 'press-key'; SecondId = 'press-enter' }
        @{ Case = 'two such phrases in one file'; First = "  greet:`n    sentence: ""greet <name>""`n    screen:`n      - action: inputText`n        text: ""<name>""`n"
            Second = "  hello:`n    sentence: ""GREET <who>""`n    screen:`n      - action: inputText`n        text: ""<who>""`n"; OneFile = $true; FirstId = 'greet'; SecondId = 'hello' }
    ) {
        $dir = New-PhraseCaseDir
        if ($OneFile) {
            $path = Join-Path $dir '_phrases.yml'
            Write-PhraseText -Path $path -Content ("phrases:`n" + $First + $Second)
            $source = @(@{ Path = $path; Tier = 'framework' })
        } else {
            $firstPath = Join-Path $dir 'a/_phrases.yml'
            $secondPath = Join-Path $dir 'b/_phrases.yml'
            Write-PhraseText -Path $firstPath -Content ("phrases:`n" + $First)
            Write-PhraseText -Path $secondPath -Content ("phrases:`n" + $Second)
            $source = @(@{ Path = $firstPath; Tier = 'framework' }, @{ Path = $secondPath; Tier = 'project' })
        }
        $caught = Get-CaughtException { $null = Get-StepPhraseLibrary -Source $source }
        Assert-StringEqual -Expected 'runner.step_phrase_overlap' -Actual $caught.Data['YurunaMessageCode']
        Assert-True $caught.Message.Contains("'$FirstId'") $caught.Message
        Assert-True $caught.Message.Contains("'$SecondId'") $caught.Message
    }

    It 'rejects <Case> in the schema and in the reader' -TestCases @(
        @{ Case = 'a phrase without sentence'; Reason = 'sentence'; Text = "phrases:`n  go:`n    screen:`n      - action: pressKey`n        name: Enter`n" }
        @{ Case = 'a phrase without surface'; Reason = 'no-surface'; Text = "phrases:`n  go:`n    sentence: ""go now""`n" }
        @{ Case = 'an empty surface'; Reason = 'empty-surface'; Text = "phrases:`n  go:`n    sentence: ""go now""`n    screen: []`n" }
        @{ Case = 'the id Press'; Reason = 'phrase-id'; Text = "phrases:`n  Press:`n    sentence: ""go now""`n    screen:`n      - action: pressKey`n        name: Enter`n" }
        @{ Case = 'a sentence that starts with a slot'; Reason = 'sentence'; Text = "phrases:`n  go:`n    sentence: ""<k:key> now""`n    screen:`n      - action: pressKey`n        name: ""<k>""`n" }
        @{ Case = 'a double space'; Reason = 'sentence'; Text = "phrases:`n  go:`n    sentence: ""press  <k:key>""`n    screen:`n      - action: pressKey`n        name: ""<k>""`n" }
        @{ Case = 'an unknown slot type'; Reason = 'sentence'; Text = "phrases:`n  go:`n    sentence: ""press <k:number>""`n    screen:`n      - action: pressKey`n        name: ""<k>""`n" }
        @{ Case = 'a template with snippet'; Reason = 'template-step'; Text = "phrases:`n  go:`n    sentence: ""go now""`n    screen:`n      - action: pressKey`n        name: Enter`n        snippet: prime`n" }
        @{ Case = 'a template with step under steps'; Reason = 'template-step'; Text = "phrases:`n  go:`n    sentence: ""go now""`n    screen:`n      - action: retry`n        steps:`n          - step: ""press Enter""`n" }
        @{ Case = 'a template with description'; Reason = 'template-step'; Text = "phrases:`n  go:`n    sentence: ""go now""`n    screen:`n      - action: pressKey`n        name: Enter`n        description: x`n" }
        @{ Case = 'an extra top-level key'; Reason = 'root'; Text = "phrases:`n  go:`n    sentence: ""go now""`n    screen:`n      - action: pressKey`n        name: Enter`nextra: 1`n" }
    ) {
        $path = Join-Path (New-PhraseCaseDir) '_phrases.yml'
        Write-PhraseText -Path $path -Content $Text
        $json = Get-Content -Raw -LiteralPath $path | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        Assert-False (Test-Json -Json $json -Schema $script:PhraseSchemaJson -ErrorAction SilentlyContinue) 'the schema refuses it'
        $caught = Get-CaughtException { $null = Get-StepPhraseLibrary -Source @(@{ Path = $path; Tier = 'framework' }) }
        Assert-StringEqual -Expected 'runner.step_phrase_library_invalid' -Actual $caught.Data['YurunaMessageCode']
        Assert-True $caught.Message.Contains("($Reason)") $caught.Message
    }

    It 'rejects <Case> in the reader' -TestCases @(
        @{ Case = 'a duplicate slot'; Reason = 'duplicate-slot'; Detail = ''; Text = "phrases:`n  go:`n    sentence: ""go <a> <a>""`n    screen:`n      - action: inputText`n        text: ""<a>""`n" }
        @{ Case = 'an unknown slot reference'; Reason = 'unknown-slot'; Detail = ''; Text = "phrases:`n  go:`n    sentence: ""go <a>""`n    screen:`n      - action: inputText`n        text: ""<a> <b>""`n" }
        @{ Case = 'an unused slot'; Reason = 'unused-slot'; Detail = ''; Text = "phrases:`n  go:`n    sentence: ""go <a>""`n    screen:`n      - action: inputText`n        text: ""hi""`n" }
        @{ Case = 'an unknown action'; Reason = 'unknown-action'; Detail = ''; Text = "phrases:`n  go:`n    sentence: ""go now""`n    screen:`n      - action: fly`n" }
        @{ Case = 'a secret slot in a label'; Reason = 'secret-slot-field'; Detail = 'screen[1] label'; Text = "phrases:`n  tap-secret:`n    sentence: ""tap secret <pw:secret>""`n    screen:`n      - action: tapOn`n        label: ""<pw>""`n" }
        @{ Case = 'a secret slot in a list'; Reason = 'secret-slot-field'; Detail = 'screen[1] pattern'; Text = "phrases:`n  wait-secret:`n    sentence: ""wait secret <pw:secret>""`n    screen:`n      - action: waitForText`n        pattern: [""<pw>""]`n" }
    ) {
        $path = Join-Path (New-PhraseCaseDir) '_phrases.yml'
        Write-PhraseText -Path $path -Content $Text
        $caught = Get-CaughtException { $null = Get-StepPhraseLibrary -Source @(@{ Path = $path; Tier = 'framework' }) }
        Assert-StringEqual -Expected 'runner.step_phrase_library_invalid' -Actual $caught.Data['YurunaMessageCode']
        Assert-True $caught.Message.Contains("($Reason)") $caught.Message
        if ($Detail) { Assert-True $caught.Message.Contains($Detail) $caught.Message }
    }

    It 'accepts a secret slot in text and in command' {
        $library = Read-FixtureLibrary -Content @'
phrases:
  say-secret:
    sentence: "say secret <pw:secret>"
    screen:
      - action: inputTextAndEnter
        text: "<pw>"
  run-secret:
    sentence: "run secret <cmd:secret>"
    screen:
      - action: sshExec
        command: "<cmd>"
'@
        foreach ($sentence in 'say secret hunter2', 'run secret hunter2') {
            $steps = @(Resolve-StepPhrase -Sentence $sentence -Surface screen -Library $library)
            Assert-True ($steps[0].sensitive -eq $true) "$sentence is sensitive"
            Assert-True $steps[0].description.Contains('***') "description: $($steps[0].description)"
            Assert-False $steps[0].description.Contains('hunter2') "description: $($steps[0].description)"
        }
    }

    It 'rejects a template the step schema refuses (<Case>)' -TestCases @(
        @{ Case = 'waitForSeconds without seconds'; Text = "phrases:`n  pause:`n    sentence: ""pause now""`n    screen:`n      - action: waitForSeconds`n" }
        @{ Case = 'seconds from a text slot'; Text = "phrases:`n  pause:`n    sentence: ""pause <t>""`n    screen:`n      - action: waitForSeconds`n        seconds: ""<t>""`n" }
        @{ Case = 'a pressKey name from a text slot'; Text = "phrases:`n  hit:`n    sentence: ""hit <t>""`n    screen:`n      - action: pressKey`n        name: ""<t>""`n" }
    ) {
        $path = Join-Path (New-PhraseCaseDir) '_phrases.yml'
        Write-PhraseText -Path $path -Content $Text
        $caught = Get-CaughtException { $null = Get-StepPhraseLibrary -Source @(@{ Path = $path; Tier = 'framework' }) }
        Assert-StringEqual -Expected 'runner.step_phrase_template_invalid' -Actual $caught.Data['YurunaMessageCode']
    }

    It 'accepts the framework library in the schema and in the reader' {
        $json = Get-Content -Raw -LiteralPath $script:FrameworkLibraryPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        Assert-True (Test-Json -Json $json -Schema $script:PhraseSchemaJson -ErrorAction SilentlyContinue) 'the schema accepts the framework library'
        $library = Get-StepPhraseLibrary -Source @(@{ Path = $script:FrameworkLibraryPath; Tier = 'framework' })
        Assert-Equal -Expected 19 -Actual @($library.Phrases).Count -Because 'the starter vocabulary has nineteen phrases'
    }

    It 'loads one physical file once' {
        $library = Get-StepPhraseLibrary -Source @(
            @{ Path = $script:FrameworkLibraryPath; Tier = 'framework' }
            @{ Path = (Join-Path $script:RepoRoot 'test/../test/sequences/_phrases.yml'); Tier = 'project' })
        Assert-Equal -Expected @($script:Starter.Phrases).Count -Actual @($library.Phrases).Count
    }

    It 'sees an edit, an added file and a removed file' {
        $dir = New-PhraseCaseDir
        $first = Join-Path $dir 'a/_phrases.yml'
        $second = Join-Path $dir 'b/_phrases.yml'
        $one = "  go:`n    sentence: ""go now""`n    screen:`n      - action: pressKey`n        name: Enter`n"
        $two = "  stop:`n    sentence: ""stop now""`n    screen:`n      - action: pressKey`n        name: Escape`n"
        $three = "  wait:`n    sentence: ""hold on""`n    screen:`n      - action: waitForSeconds`n        seconds: 1`n"
        Write-PhraseText -Path $first -Content ("phrases:`n" + $one)
        $source = @(@{ Path = $first; Tier = 'framework' })
        Assert-Equal -Expected 1 -Actual @((Get-StepPhraseLibrary -Source $source).Phrases).Count
        $stamp = (Get-Item -LiteralPath $first).LastWriteTimeUtc
        Write-PhraseText -Path $first -Content ("phrases:`n" + $one + $two)
        (Get-Item -LiteralPath $first).LastWriteTimeUtc = $stamp.AddSeconds(2)
        Assert-Equal -Expected 2 -Actual @((Get-StepPhraseLibrary -Source $source).Phrases).Count -Because 'an edit is seen'
        Write-PhraseText -Path $second -Content ("phrases:`n" + $three)
        $both = @($source) + @(@{ Path = $second; Tier = 'project' })
        Assert-Equal -Expected 3 -Actual @((Get-StepPhraseLibrary -Source $both).Phrases).Count -Because 'an added file is seen'
        Assert-Equal -Expected 2 -Actual @((Get-StepPhraseLibrary -Source $source).Phrases).Count -Because 'a removed file is seen'
    }

    It 'keeps at most eight compiled libraries' {
        $counts = @(foreach ($set in 1..9) {
            $path = Join-Path (New-PhraseCaseDir) '_phrases.yml'
            Write-PhraseText -Path $path -Content "phrases:`n  go$set`:`n    sentence: ""go number$set""`n    screen:`n      - action: pressKey`n        name: Enter`n"
            $null = Get-StepPhraseLibrary -Source @(@{ Path = $path; Tier = 'framework' })
            InModuleScope Test.StepPhrase { $script:StepPhraseLibraryCache.Count }
        })
        Assert-Equal -Expected 9 -Actual $counts.Count
        foreach ($count in $counts) { Assert-True ($count -le 8) "the cache held $count libraries" }
    }

    It 'raises errors the planner recognizes' {
        $caught = $null
        try { $null = @(Resolve-StepPhrase -Sentence 'no such sentence' -Surface screen -Library $script:Starter) } catch { $caught = $_ }
        Assert-NotNull $caught 'the call must fail'
        Assert-True (Test-SequencePlannerFailure -ErrorObject $caught) 'the planner treats it as an invalid plan'
        Assert-True $caught.Exception.Message.StartsWith('PlannerFatal: ') $caught.Exception.Message
    }
}

Describe 'a sentence is written back from values' {
    It 'writes a sentence that reads back (<Value>)' -TestCases @(
        @{ Value = 'Next'; Expected = 'click button Next' }
        @{ Value = 'I agree'; Expected = "click button 'I agree'" }
        @{ Value = "it's"; Expected = "click button it's" }
        @{ Value = "Don't save"; Expected = 'click button "Don''t save"' }
        @{ Value = 'say "hi"'; Expected = '' }
        @{ Value = 'both '' and "'; Expected = '' }
        @{ Value = '${a} ${b}'; Expected = '' }
        @{ Value = '${ext:a.B(${x}, ${y})}'; Expected = '' }
        @{ Value = 'a${'; Expected = '' }
        @{ Value = "line one`nline two"; Expected = '' }
    ) {
        $phrase = $script:Starter.Phrases | Where-Object { $_.Id -ceq 'click-button' }
        $sentence = Format-StepPhraseSentence -Phrase $phrase -Value @{ label = $Value }
        if ($Expected) { Assert-True ($sentence -ceq $Expected) "written as: $sentence" }
        $found = Find-StepPhrase -Sentence $sentence -Library $script:Starter
        Assert-StringEqual -Expected 'click-button' -Actual $found.Phrase.Id
        Assert-True ($found.Values['label'].Value -ceq $Value) "read back as '$($found.Values['label'].Value)'"
    }
}
