<#PSScriptInfo
.VERSION 2026.11.23
.GUID 429fd4b0-8b00-4ec2-bb5e-d495a36950c5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence phrase
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

# Step sentences: a sequence step written as `step: "<sentence>"` is replaced,
# when the file is read, by the action steps of the one phrase of a
# _phrases.yml library that the sentence matches. Nothing here runs at cycle
# time. The module is a leaf: the sequence reader imports it, never the other
# way round, so its planner errors are built here rather than borrowed.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# The verb set, timeout verbs, required fields and pressKey names read from
# sequence.schema.yml, keyed by that file's stamp. One entry.
$script:StepPhraseContract = $null
# Resolved library path -> @{ Stamp; Parsed }.
$script:StepPhraseFileCache = @{}
# Library stamp -> compiled library. Bounded: cleared before a ninth entry.
$script:StepPhraseLibraryCache = @{}

$script:StepPhraseSentenceLimit = 2000
$script:StepPhraseIntegerPattern = '^(0|[1-9][0-9]{0,8})$'
$script:StepPhraseSentencePattern = '^[A-Za-z][A-Za-z0-9-]*( ([A-Za-z][A-Za-z0-9-]*|<[A-Za-z][A-Za-z0-9]*(:(secret|int|key))?>)){0,11}$'
$script:StepPhraseSlotPattern = '^<([A-Za-z][A-Za-z0-9]*)(?::(secret|int|key))?>$'
$script:StepPhraseReferencePattern = '<([A-Za-z][A-Za-z0-9]*)>'
$script:StepPhraseIdPattern = '^[a-z][a-z0-9]*(-[a-z0-9]+)*$'

function New-StepPhraseException {
    <# .SYNOPSIS
        Create a localized sentence planning failure with an invariant control identity.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory exception; no external state changes.')]
    [CmdletBinding()]
    [OutputType([InvalidOperationException])]
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Arguments = @{})
    $message = Format-YurunaOperatorMessage -Key $Key -Arguments $Arguments
    $exception = [InvalidOperationException]::new('PlannerFatal: ' + $message)
    $exception.Data['YurunaFailureCode'] = 'sequence.plan_invalid'
    $exception.Data['YurunaMessageCode'] = $Key
    return $exception
}

function Read-StepPhraseExpression {
    <# .SYNOPSIS
        Return the index after the ${...} expression that starts at -Index.
    .DESCRIPTION
        Checks balance only: `$$` is skipped, `${` and `(` open, `}` and `)`
        must close the innermost opener. Every other character, white space
        included, belongs to the expression.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Index,
        [string]$Location = ''
    )
    $closers = [Collections.Generic.Stack[char]]::new()
    $closers.Push([char]'}')
    $i = $Index + 2
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($c -ceq '$' -and $next -ceq '$') { $i += 2; continue }
        if ($c -ceq '$' -and $next -ceq '{') { $closers.Push([char]'}'); $i += 2; continue }
        if ($c -ceq '(') { $closers.Push([char]')'); $i++; continue }
        if ($c -ceq ')' -or $c -ceq '}') {
            if ($closers.Peek() -cne $c) {
                throw (New-StepPhraseException -Key 'runner.step_phrase_malformed' -Arguments @{ location = "$Location"; reason = 'unbalanced-expression'; position = "$($i + 1)" })
            }
            [void]$closers.Pop()
            $i++
            if ($closers.Count -eq 0) { return $i }
            continue
        }
        $i++
    }
    throw (New-StepPhraseException -Key 'runner.step_phrase_malformed' -Arguments @{ location = "$Location"; reason = 'unterminated-expression'; position = "$($Index + 1)" })
}

function ConvertTo-StepPhraseToken {
    <# .SYNOPSIS
        Split a step sentence into word and quoted tokens.
    .DESCRIPTION
        Writes one [pscustomobject] per token (Kind, Value, Source,
        HasExpression, Start) to the output stream; callers read the result
        as @(...). A ${...} expression is one part of a word, white space
        inside it included. Errors name the 1-based character position and
        never the sentence.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sentence,
        [string]$Location = ''
    )
    if ($Sentence.Length -gt $script:StepPhraseSentenceLimit) {
        throw (New-StepPhraseException -Key 'runner.step_phrase_malformed' -Arguments @{ location = "$Location"; reason = 'too-long'; position = "$($script:StepPhraseSentenceLimit + 1)" })
    }
    $count = 0
    $i = 0
    $n = $Sentence.Length
    while ($true) {
        while ($i -lt $n -and [char]::IsWhiteSpace($Sentence[$i])) { $i++ }
        if ($i -ge $n) { break }
        $start = $i
        $quote = $Sentence[$i]
        if ($quote -ceq "'" -or $quote -ceq '"') {
            $builder = [Text.StringBuilder]::new()
            $closed = $false
            $i++
            while ($i -lt $n) {
                if ($Sentence[$i] -ceq $quote) {
                    if ($i + 1 -lt $n -and $Sentence[$i + 1] -ceq $quote) { [void]$builder.Append($quote); $i += 2; continue }
                    $closed = $true
                    $i++
                    break
                }
                [void]$builder.Append($Sentence[$i])
                $i++
            }
            if (-not $closed) {
                throw (New-StepPhraseException -Key 'runner.step_phrase_malformed' -Arguments @{ location = "$Location"; reason = 'unterminated-quote'; position = "$($start + 1)" })
            }
            if ($i -lt $n -and -not [char]::IsWhiteSpace($Sentence[$i])) {
                throw (New-StepPhraseException -Key 'runner.step_phrase_malformed' -Arguments @{ location = "$Location"; reason = 'text-after-quote'; position = "$($i + 1)" })
            }
            $text = $builder.ToString()
            $count++
            [pscustomobject]@{ Kind = 'quoted'; Value = $text; Source = $Sentence.Substring($start, $i - $start); HasExpression = $text.Contains('${'); Start = $start }
            continue
        }
        $hasExpression = $false
        while ($i -lt $n -and -not [char]::IsWhiteSpace($Sentence[$i])) {
            $next = if ($i + 1 -lt $n) { $Sentence[$i + 1] } else { [char]0 }
            if ($Sentence[$i] -ceq '$' -and $next -ceq '$') { $i += 2; continue }
            if ($Sentence[$i] -ceq '$' -and $next -ceq '{') {
                $i = Read-StepPhraseExpression -Text $Sentence -Index $i -Location $Location
                $hasExpression = $true
                continue
            }
            $i++
        }
        $word = $Sentence.Substring($start, $i - $start)
        $count++
        [pscustomobject]@{ Kind = 'word'; Value = $word; Source = $word; HasExpression = $hasExpression; Start = $start }
    }
    if ($count -eq 0) {
        throw (New-StepPhraseException -Key 'runner.step_phrase_malformed' -Arguments @{ location = "$Location"; reason = 'empty'; position = '1' })
    }
}

function Import-StepPhraseYamlModule {
    <# .SYNOPSIS
        Load powershell-yaml on first use, as the sequence reader does.
    #>
    [CmdletBinding()]
    param()
    if (Get-Module powershell-yaml) { return }
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_c959d88998b87c80' -Arguments @{ command = 'Install-Module -Name powershell-yaml -Scope CurrentUser' })
    }
    Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
}

function Get-StepPhraseStepContract {
    <# .SYNOPSIS
        Read the verbs, timeout verbs, required fields and pressKey names from sequence.schema.yml.
    .DESCRIPTION
        Re-read only when the file's stamp (path, write time, length) changes.
        StepSchemaJson wraps the file's $defs so Test-Json can validate one
        generated step against actionStep.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $path = Join-Path $PSScriptRoot '../schemas/sequence.schema.yml'
    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $stamp = "$($item.FullName)|$($item.LastWriteTimeUtc.Ticks)|$($item.Length)"
    } catch {
        throw (New-StepPhraseException -Key 'runner.step_phrase_file_unreadable' -Arguments @{ file = "$path"; message = "$($_.Exception.Message)" })
    }
    if ($script:StepPhraseContract -and $script:StepPhraseContract.Stamp -ceq $stamp) { return $script:StepPhraseContract }
    Import-StepPhraseYamlModule
    try {
        $document = Get-Content -Raw -LiteralPath $item.FullName -ErrorAction Stop | ConvertFrom-Yaml -Ordered
    } catch {
        throw (New-StepPhraseException -Key 'runner.step_phrase_file_unreadable' -Arguments @{ file = "$($item.FullName)"; message = "$($_.Exception.Message)" })
    }
    $definitions = if ($document -is [Collections.IDictionary]) { $document['$defs'] } else { $null }
    $actionStep = if ($definitions -is [Collections.IDictionary]) { $definitions['actionStep'] } else { $null }
    $enum = @(if ($actionStep -is [Collections.IDictionary]) { $actionStep['properties']['action']['enum'] })
    if ($enum.Count -eq 0) {
        throw (New-StepPhraseException -Key 'runner.step_phrase_file_unreadable' -Arguments @{ file = "$($item.FullName)"; message = 'no-action-enum' })
    }
    $verb = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $enum) { [void]$verb.Add([string]$name) }
    $timeout = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $required = [Collections.Generic.Dictionary[string, string[]]]::new([StringComparer]::Ordinal)
    $keyName = @()
    foreach ($branch in @($actionStep['allOf'])) {
        if ($branch -isnot [Collections.IDictionary]) { continue }
        $condition = $branch['if']['properties']['action']
        $names = @(if ($condition.Contains('const')) { [string]$condition['const'] } elseif ($condition.Contains('enum')) { @($condition['enum'] | ForEach-Object { [string]$_ }) })
        $then = $branch['then']
        $fields = if ($then -is [Collections.IDictionary] -and $then['properties'] -is [Collections.IDictionary]) { $then['properties'] } else { @{} }
        foreach ($name in $names) {
            $required[$name] = [string[]]@(if ($then -is [Collections.IDictionary] -and $then.Contains('required')) { $then['required'] | ForEach-Object { [string]$_ } })
            if ($fields.Contains('timeoutSeconds')) { [void]$timeout.Add($name) }
        }
        if ($names -ccontains 'pressKey' -and $fields.Contains('name')) { $keyName = @($fields['name']['enum'] | ForEach-Object { [string]$_ }) }
    }
    if ($keyName.Count -eq 0) {
        throw (New-StepPhraseException -Key 'runner.step_phrase_file_unreadable' -Arguments @{ file = "$($item.FullName)"; message = 'no-presskey-names' })
    }
    $wrapper = [ordered]@{ '$schema' = 'https://json-schema.org/draft/2020-12/schema'; '$defs' = $definitions; '$ref' = '#/$defs/actionStep' }
    $script:StepPhraseContract = @{
        Stamp          = $stamp
        Verb           = $verb
        Timeout        = $timeout
        Required       = $required
        KeyName        = [string[]]$keyName
        StepSchemaJson = (ConvertTo-Json -InputObject $wrapper -Depth 32)
    }
    return $script:StepPhraseContract
}

function Get-StepPhraseSlotReference {
    <# .SYNOPSIS
        List the <name> references in every text value under a template node.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Node)
    if ($Node -is [string]) {
        foreach ($match in [regex]::Matches($Node, $script:StepPhraseReferencePattern)) { $match.Groups[1].Value }
        return
    }
    if ($Node -is [Collections.IDictionary]) {
        foreach ($key in $Node.Keys) { Get-StepPhraseSlotReference -Node $Node[$key] }
        return
    }
    if ($Node -is [Collections.IEnumerable]) {
        foreach ($item in $Node) { Get-StepPhraseSlotReference -Node $item }
    }
}

function Get-StepPhraseLibrary {
    <# .SYNOPSIS
        Load and check phrase libraries, in load order, into one library.
    .DESCRIPTION
        Each source is @{ Path; Tier } with Tier framework or project. A path
        listed twice loads once. The result is cached by the stamp of the step
        schema and of every file, so an edit, an added file or a removed file
        is seen on the next call. A phrase id is defined once across all files,
        and no two phrases may match the same sentence.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Source)
    $contract = Get-StepPhraseStepContract
    $files = [Collections.Generic.List[hashtable]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Source) {
        $entryPath = [string]$entry.Path
        try {
            $resolved = (Resolve-Path -LiteralPath $entryPath -ErrorAction Stop).Path
            $item = Get-Item -LiteralPath $resolved -ErrorAction Stop
        } catch {
            throw (New-StepPhraseException -Key 'runner.step_phrase_file_unreadable' -Arguments @{ file = "$entryPath"; message = "$($_.Exception.Message)" })
        }
        if (-not $seen.Add($resolved)) { continue }
        $fileStamp = "$($item.LastWriteTimeUtc.Ticks)|$($item.Length)"
        $cached = $script:StepPhraseFileCache[$resolved]
        if ($cached -and $cached.Stamp -ceq $fileStamp) {
            $parsed = $cached.Parsed
        } else {
            Import-StepPhraseYamlModule
            try {
                $parsed = Get-Content -Raw -LiteralPath $resolved -ErrorAction Stop | ConvertFrom-Yaml -Ordered
            } catch {
                throw (New-StepPhraseException -Key 'runner.step_phrase_file_unreadable' -Arguments @{ file = "$resolved"; message = "$($_.Exception.Message)" })
            }
            $script:StepPhraseFileCache[$resolved] = @{ Stamp = $fileStamp; Parsed = $parsed }
        }
        $files.Add(@{ Path = $resolved; Tier = [string]$entry.Tier; Stamp = "$([string]$entry.Tier)|$resolved|$fileStamp"; Parsed = $parsed })
    }
    $stamp = (@($contract.Stamp) + @($files | ForEach-Object { $_.Stamp })) -join "`n"
    if ($script:StepPhraseLibraryCache.ContainsKey($stamp)) { return $script:StepPhraseLibraryCache[$stamp] }

    $phrases = [Collections.Generic.List[object]]::new()
    $vocabulary = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $root = $file.Parsed
        $libraryFile = $file.Path
        $rootKeys = @(if ($root -is [Collections.IDictionary]) { $root.Keys | ForEach-Object { [string]$_ } })
        if ($root -isnot [Collections.IDictionary] -or $rootKeys.Count -ne 1 -or $rootKeys[0] -cne 'phrases' -or
            $root['phrases'] -isnot [Collections.IDictionary] -or $root['phrases'].Count -eq 0) {
            $detail = if ($root -is [Collections.IDictionary]) { $rootKeys -join ', ' } else { 'not-a-map' }
            throw (New-StepPhraseException -Key 'runner.step_phrase_library_invalid' -Arguments @{ file = "$libraryFile"; reason = 'root'; phrase = ''; detail = "$detail" })
        }
        foreach ($idKey in $root['phrases'].Keys) {
            $id = [string]$idKey
            $definition = $root['phrases'][$idKey]
            $invalid = {
                param([string]$Reason, [string]$Detail)
                New-StepPhraseException -Key 'runner.step_phrase_library_invalid' -Arguments @{ file = "$libraryFile"; reason = $Reason; phrase = "$id"; detail = "$Detail" }
            }
            if ($id -cnotmatch $script:StepPhraseIdPattern) { throw (& $invalid 'phrase-id' $id) }
            if ($definition -isnot [Collections.IDictionary]) { throw (& $invalid 'phrase-shape' 'not-a-map') }
            $extra = @($definition.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -cnotin 'sentence', 'screen', 'page' })
            if ($extra.Count -gt 0) { throw (& $invalid 'phrase-shape' ($extra -join ', ')) }
            $sentence = $definition['sentence']
            if ($sentence -isnot [string] -or $sentence -cnotmatch $script:StepPhraseSentencePattern) { throw (& $invalid 'sentence' 'grammar') }

            $elements = [Collections.Generic.List[hashtable]]::new()
            $slots = [ordered]@{}
            foreach ($part in $sentence.Split(' ')) {
                $slotMatch = [regex]::Match($part, $script:StepPhraseSlotPattern)
                if ($slotMatch.Success) {
                    $slotName = $slotMatch.Groups[1].Value
                    $slotType = if ($slotMatch.Groups[2].Success) { $slotMatch.Groups[2].Value } else { 'text' }
                    if ($slots.Contains($slotName)) { throw (& $invalid 'duplicate-slot' $slotName) }
                    $slots[$slotName] = $slotType
                    $elements.Add(@{ Kind = 'slot'; Text = $part; Name = $slotName; Type = $slotType })
                } else {
                    $elements.Add(@{ Kind = 'literal'; Text = $part; Name = $null; Type = $null })
                }
            }
            $surfaces = [ordered]@{}
            foreach ($surfaceName in 'screen', 'page') {
                if ($definition.Contains($surfaceName)) { $surfaces[$surfaceName] = $definition[$surfaceName] }
            }
            if ($surfaces.Count -eq 0) { throw (& $invalid 'no-surface' '') }
            foreach ($surfaceName in $surfaces.Keys) {
                $template = $surfaces[$surfaceName]
                if ($template -isnot [Collections.IList] -or $template.Count -eq 0) { throw (& $invalid 'empty-surface' $surfaceName) }
            }

            # Template steps, depth first in file order; the first failure wins.
            foreach ($surfaceName in $surfaces.Keys) {
                $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                $pending = [Collections.Generic.Stack[object]]::new()
                $top = @($surfaces[$surfaceName])
                for ($at = $top.Count - 1; $at -ge 0; $at--) { $pending.Push(@{ Node = $top[$at]; Position = "$surfaceName[$($at + 1)]" }) }
                while ($pending.Count -gt 0) {
                    $work = $pending.Pop()
                    $templateStep = $work.Node
                    $position = $work.Position
                    if ($templateStep -isnot [Collections.IDictionary]) { throw (& $invalid 'template-step' "$position action") }
                    $refused = @($templateStep.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -in 'step', 'snippet', 'description', 'descriptionLocalized', 'fromStep' })
                    if ($refused.Count -gt 0) { throw (& $invalid 'template-step' "$position $($refused -join ', ')") }
                    $action = $templateStep['action']
                    if ($action -isnot [string] -or $action.Contains('<')) { throw (& $invalid 'template-step' "$position action") }
                    if (-not $contract.Verb.Contains($action)) { throw (& $invalid 'unknown-action' "$position $action") }
                    $fieldReference = [ordered]@{}
                    foreach ($fieldKey in $templateStep.Keys) {
                        if ([string]$fieldKey -in 'steps', 'stepsAfterVmRestart') { continue }
                        $fieldReference[[string]$fieldKey] = @(Get-StepPhraseSlotReference -Node $templateStep[$fieldKey])
                    }
                    foreach ($fieldKey in $fieldReference.Keys) {
                        foreach ($reference in $fieldReference[$fieldKey]) {
                            if (-not $slots.Contains($reference)) { throw (& $invalid 'unknown-slot' "$position <$reference>") }
                            [void]$referenced.Add($reference)
                        }
                    }
                    foreach ($fieldKey in $fieldReference.Keys) {
                        $secretReference = @($fieldReference[$fieldKey] | Where-Object { $slots[$_] -ceq 'secret' })
                        if ($secretReference.Count -eq 0) { continue }
                        if ($fieldKey -cnotin 'text', 'command' -or $templateStep[$fieldKey] -isnot [string]) { throw (& $invalid 'secret-slot-field' "$position $fieldKey") }
                    }
                    foreach ($nestedKey in 'stepsAfterVmRestart', 'steps') {
                        if (-not $templateStep.Contains($nestedKey)) { continue }
                        $nested = @($templateStep[$nestedKey])
                        for ($at = $nested.Count - 1; $at -ge 0; $at--) { $pending.Push(@{ Node = $nested[$at]; Position = "$position.$nestedKey[$($at + 1)]" }) }
                    }
                }
                foreach ($slotName in $slots.Keys) {
                    if (-not $referenced.Contains($slotName)) { throw (& $invalid 'unused-slot' "$surfaceName <$slotName>") }
                }
            }

            # Each top-level template step must be a valid step of its verb once
            # its slots hold sample values.
            $probeValue = @{}
            $probeType = @{}
            foreach ($slotName in $slots.Keys) {
                $probeType[$slotName] = $slots[$slotName]
                $probeValue[$slotName] = switch ($slots[$slotName]) { 'int' { 0 } 'key' { 'Enter' } default { 'x' } }
            }
            $probeSet = @(, $probeValue)
            if (@($slots.Values) -ccontains 'int') {
                $wide = @{}
                foreach ($slotName in $probeValue.Keys) { $wide[$slotName] = if ($slots[$slotName] -ceq 'int') { 999999999 } else { $probeValue[$slotName] } }
                $probeSet += , $wide
            }
            foreach ($surfaceName in $surfaces.Keys) {
                $top = @($surfaces[$surfaceName])
                for ($at = 0; $at -lt $top.Count; $at++) {
                    $templateStep = $top[$at]
                    $action = [string]$templateStep['action']
                    $needed = @(if ($contract.Required.ContainsKey($action)) { $contract.Required[$action] })
                    $valid = $true
                    foreach ($field in $needed) { if (-not $templateStep.Contains($field)) { $valid = $false } }
                    if ($valid) {
                        foreach ($sample in $probeSet) {
                            $probe = (Expand-StepPhraseNode -Node $templateStep -Value $sample -Type $probeType).Node
                            $probeJson = ConvertTo-Json -InputObject $probe -Depth 32 -Compress
                            if (-not (Test-Json -Json $probeJson -Schema $contract.StepSchemaJson -ErrorAction SilentlyContinue)) { $valid = $false }
                        }
                    }
                    if (-not $valid) {
                        $requiredText = if ($needed.Count -gt 0) { $needed -join ', ' } else { '-' }
                        throw (New-StepPhraseException -Key 'runner.step_phrase_template_invalid' -Arguments @{ index = "$($at + 1)"; phrase = "$id"; surface = "$surfaceName"; file = "$libraryFile"; action = "$action"; required = "$requiredText" })
                    }
                }
            }

            $shape = @($elements | ForEach-Object { if ($_.Kind -ceq 'slot') { '<>' } else { $_.Text.ToLowerInvariant() } }) -join ' '
            $phrase = [pscustomobject]@{
                Id       = $id
                Sentence = $sentence
                Elements = $elements.ToArray()
                Slots    = $slots
                Shape    = $shape
                Surfaces = $surfaces
                File     = $libraryFile
                Tier     = $file.Tier
            }
            foreach ($earlier in $phrases) {
                if ($earlier.Id -ceq $phrase.Id) {
                    throw (New-StepPhraseException -Key 'runner.step_phrase_duplicate_id' -Arguments @{ phrase = "$id"; first = "$($earlier.File)"; second = "$libraryFile" })
                }
                if ($earlier.Elements.Count -ne $phrase.Elements.Count) { continue }
                $overlap = $true
                for ($at = 0; $at -lt $phrase.Elements.Count; $at++) {
                    $left = $earlier.Elements[$at]
                    $right = $phrase.Elements[$at]
                    if ($left.Kind -ceq 'literal' -and $right.Kind -ceq 'literal' -and
                        -not [string]::Equals($left.Text, $right.Text, [StringComparison]::OrdinalIgnoreCase)) { $overlap = $false; break }
                }
                if ($overlap) {
                    throw (New-StepPhraseException -Key 'runner.step_phrase_overlap' -Arguments @{
                        firstPhrase = "$($earlier.Id)"; firstSentence = "$($earlier.Sentence)"; firstFile = "$($earlier.File)"
                        secondPhrase = "$id"; secondSentence = "$sentence"; secondFile = "$libraryFile" })
                }
            }
            $phrases.Add($phrase)
        }
    }
    foreach ($phrase in $phrases) {
        foreach ($element in $phrase.Elements) { if ($element.Kind -ceq 'literal') { [void]$vocabulary.Add($element.Text) } }
    }
    $library = @{ Phrases = $phrases.ToArray(); Vocabulary = $vocabulary; Stamp = $stamp }
    if ($script:StepPhraseLibraryCache.Count -ge 8) { $script:StepPhraseLibraryCache.Clear() }
    $script:StepPhraseLibraryCache[$stamp] = $library
    return $library
}

function Test-StepPhraseLiteralToken {
    <# .SYNOPSIS
        True when a token can stand for a literal word of a phrase.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Token, [Parameter(Mandatory)][string]$Literal)
    return ($Token.Kind -ceq 'word' -and -not $Token.HasExpression -and
        [string]::Equals($Token.Value, $Literal, [StringComparison]::OrdinalIgnoreCase))
}

function Find-StepPhrase {
    <# .SYNOPSIS
        Find the one phrase a sentence matches and read its slot values.
    .DESCRIPTION
        Returns @{ Phrase; Tokens; Values; Masked }. Values maps each slot name
        to @{ Value; Source; Type }; Masked is the sentence with secret values
        and extension calls shown as ***. A sentence that matches no phrase is
        echoed only as its known literal words, with *** for every other token.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sentence,
        [Parameter(Mandatory)][hashtable]$Library,
        [string]$Location = ''
    )
    $tokens = @(ConvertTo-StepPhraseToken -Sentence $Sentence -Location $Location)
    $candidates = @($Library.Phrases)
    if ($candidates.Count -eq 0) {
        throw (New-StepPhraseException -Key 'runner.step_phrase_no_library' -Arguments @{ location = "$Location" })
    }
    $match = $null
    foreach ($candidate in $candidates) {
        if ($candidate.Elements.Count -ne $tokens.Count) { continue }
        $fits = $true
        for ($at = 0; $at -lt $tokens.Count; $at++) {
            $element = $candidate.Elements[$at]
            if ($element.Kind -ceq 'literal' -and -not (Test-StepPhraseLiteralToken -Token $tokens[$at] -Literal $element.Text)) { $fits = $false; break }
        }
        if ($fits) { $match = $candidate; break }
    }
    if ($null -eq $match) {
        $shape = @($tokens | ForEach-Object {
            if ($_.Kind -ceq 'word' -and -not $_.HasExpression -and $Library.Vocabulary.Contains($_.Value)) { $_.Source } else { '***' }
        }) -join ' '
        $ranked = [Collections.Generic.List[object]]::new()
        for ($order = 0; $order -lt $candidates.Count; $order++) {
            $elements = $candidates[$order].Elements
            $rows = $tokens.Count
            $columns = $elements.Count
            $previous = [int[]]::new($columns + 1)
            for ($c = 0; $c -le $columns; $c++) { $previous[$c] = $c }
            for ($r = 1; $r -le $rows; $r++) {
                $current = [int[]]::new($columns + 1)
                $current[0] = $r
                for ($c = 1; $c -le $columns; $c++) {
                    $element = $elements[$c - 1]
                    $same = ($element.Kind -ceq 'slot') -or (Test-StepPhraseLiteralToken -Token $tokens[$r - 1] -Literal $element.Text)
                    $cost = if ($same) { 0 } else { 1 }
                    $current[$c] = [Math]::Min([Math]::Min($previous[$c] + 1, $current[$c - 1] + 1), $previous[$c - 1] + $cost)
                }
                $previous = $current
            }
            $ranked.Add([pscustomobject]@{ Distance = $previous[$columns]; Order = $order; Phrase = $candidates[$order] })
        }
        $nearest = @($ranked | Sort-Object -Property Distance, Order | Select-Object -First 3 | ForEach-Object {
            "'$($_.Phrase.Sentence)' [$(@($_.Phrase.Surfaces.Keys) -join ', ')]"
        }) -join '; '
        throw (New-StepPhraseException -Key 'runner.step_phrase_no_match' -Arguments @{ location = "$Location"; shape = "$shape"; nearest = "$nearest" })
    }
    $contract = Get-StepPhraseStepContract
    $values = [ordered]@{}
    $secretToken = [Collections.Generic.HashSet[int]]::new()
    for ($at = 0; $at -lt $tokens.Count; $at++) {
        $element = $match.Elements[$at]
        if ($element.Kind -cne 'slot') { continue }
        $token = $tokens[$at]
        $slotArguments = @{ slot = "$($element.Name)"; sentence = "$($match.Sentence)"; location = "$Location" }
        if ($token.Value.Length -eq 0) { throw (New-StepPhraseException -Key 'runner.step_phrase_slot_empty' -Arguments $slotArguments) }
        $slotValue = $token.Value
        switch ($element.Type) {
            'int' {
                if ($token.Kind -cne 'word' -or $token.HasExpression -or $token.Value -cnotmatch $script:StepPhraseIntegerPattern) {
                    throw (New-StepPhraseException -Key 'runner.step_phrase_slot_not_integer' -Arguments $slotArguments)
                }
                $slotValue = [int]$token.Value
            }
            'key' {
                $spelled = if ($token.Kind -ceq 'word' -and -not $token.HasExpression) {
                    $contract.KeyName | Where-Object { [string]::Equals($_, $token.Value, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                }
                if (-not $spelled) {
                    $slotArguments['keyNames'] = $contract.KeyName -join ', '
                    throw (New-StepPhraseException -Key 'runner.step_phrase_slot_not_key' -Arguments $slotArguments)
                }
                $slotValue = [string]$spelled
            }
            'secret' { [void]$secretToken.Add($at) }
        }
        $values[$element.Name] = @{ Value = $slotValue; Source = $token.Source; Type = $element.Type }
    }
    $masked = @(for ($at = 0; $at -lt $tokens.Count; $at++) {
        if ($secretToken.Contains($at) -or $tokens[$at].Source.Contains('${ext:')) { '***' } else { $tokens[$at].Source }
    }) -join ' '
    return @{ Phrase = $match; Tokens = $tokens; Values = $values; Masked = $masked }
}

function Expand-StepPhraseNode {
    <# .SYNOPSIS
        Copy a template node with each slot reference replaced by its value.
    .DESCRIPTION
        Returns @{ Node; Secret } and never changes the input. A text that is
        one whole reference takes the value with its type ([int] for an int
        slot); other texts are substituted in one pass by a MatchEvaluator, so
        `$1` or `$&` in a value stays as written and inserted text is not
        scanned again. A map in which a secret value was written, outside its
        nested step lists, gets `sensitive: true`; the flag stops at that map.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Node,
        [Parameter(Mandatory)][hashtable]$Value,
        [Parameter(Mandatory)][hashtable]$Type
    )
    if ($Node -is [string]) {
        $whole = [regex]::Match($Node, '^<([A-Za-z][A-Za-z0-9]*)>$')
        if ($whole.Success -and $Type.ContainsKey($whole.Groups[1].Value)) {
            $slotName = $whole.Groups[1].Value
            $slotValue = if ($Type[$slotName] -ceq 'int') { [int]$Value[$slotName] } else { [string]$Value[$slotName] }
            return @{ Node = $slotValue; Secret = ($Type[$slotName] -ceq 'secret') }
        }
        $state = @{ Secret = $false }
        $text = [regex]::Replace($Node, $script:StepPhraseReferencePattern, [Text.RegularExpressions.MatchEvaluator]{
            param($reference)
            $slotName = $reference.Groups[1].Value
            if (-not $Type.ContainsKey($slotName)) { return $reference.Value }
            if ($Type[$slotName] -ceq 'secret') { $state.Secret = $true }
            return [string]$Value[$slotName]
        })
        return @{ Node = $text; Secret = $state.Secret }
    }
    if ($Node -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        $secret = $false
        foreach ($key in $Node.Keys) {
            $child = Expand-StepPhraseNode -Node $Node[$key] -Value $Value -Type $Type
            $copy[$key] = $child.Node
            if ($child.Secret -and [string]$key -notin 'steps', 'stepsAfterVmRestart') { $secret = $true }
        }
        if ($secret) { $copy['sensitive'] = $true }
        return @{ Node = $copy; Secret = $false }
    }
    if ($Node -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        $secret = $false
        foreach ($item in $Node) {
            $child = Expand-StepPhraseNode -Node $item -Value $Value -Type $Type
            $items.Add($child.Node)
            if ($child.Secret) { $secret = $true }
        }
        return @{ Node = $items.ToArray(); Secret = $secret }
    }
    return @{ Node = $Node; Secret = $false }
}

function Hide-StepPhraseSecret {
    <# .SYNOPSIS
        Show secret values and ${ext:...} expressions of a label as ***.
    .DESCRIPTION
        The engine expands every description at run time, so an extension
        expression left in a label would run again and print its result. An
        escaped `$${ext:` is left as written: the engine does not run it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Secret
    )
    $hidden = $Text
    foreach ($candidate in @($Secret | Where-Object { $_ } | Sort-Object -Property Length -Descending)) {
        $hidden = $hidden.Replace($candidate, '***', [StringComparison]::Ordinal)
    }
    $builder = [Text.StringBuilder]::new()
    $i = 0
    while ($i -lt $hidden.Length) {
        if ($hidden[$i] -ceq '$' -and $i + 1 -lt $hidden.Length -and $hidden[$i + 1] -ceq '$') {
            [void]$builder.Append('$$')
            $i += 2
            continue
        }
        if ([string]::CompareOrdinal($hidden, $i, '${ext:', 0, 6) -eq 0) {
            [void]$builder.Append('***')
            try {
                $i = Read-StepPhraseExpression -Text $hidden -Index $i
            } catch {
                Write-Verbose "Hide-StepPhraseSecret: an unclosed extension expression is hidden to the end of the label: $($_.Exception.Message)"
                $i = $hidden.Length
            }
            continue
        }
        [void]$builder.Append($hidden[$i])
        $i++
    }
    return $builder.ToString()
}

function Resolve-StepPhrase {
    <# .SYNOPSIS
        Turn one step sentence into the action steps its phrase stands for.
    .DESCRIPTION
        Writes each generated step, an ordered dictionary, to the output
        stream; callers read the result as @(...). Each top-level step gets a
        label (the author's description, else the masked sentence, numbered
        ` (i/n)` when the phrase has several steps) and `fromStep`, the masked
        sentence. -TimeoutSeconds of 1 or more is written on every generated
        step whose verb takes a timeout.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sentence,
        [Parameter(Mandatory)][ValidateSet('screen', 'page', IgnoreCase = $false)][string]$Surface,
        [Parameter(Mandatory)][hashtable]$Library,
        [int]$TimeoutSeconds = 0,
        [string]$Description = '',
        [Collections.IDictionary]$DescriptionLocalized,
        [string]$Location = ''
    )
    $found = Find-StepPhrase -Sentence $Sentence -Library $Library -Location $Location
    $phrase = $found.Phrase
    if (-not $phrase.Surfaces.Contains($Surface)) {
        throw (New-StepPhraseException -Key 'runner.step_phrase_surface_missing' -Arguments @{
            sentence = "$($phrase.Sentence)"; location = "$Location"; surface = "$Surface"; surfaces = "$(@($phrase.Surfaces.Keys) -join ', ')" })
    }
    $slotValue = @{}
    $slotType = @{}
    $secretText = [Collections.Generic.List[string]]::new()
    foreach ($slotName in $found.Values.Keys) {
        $entry = $found.Values[$slotName]
        $slotValue[$slotName] = $entry.Value
        $slotType[$slotName] = $entry.Type
        if ($entry.Type -ceq 'secret') { $secretText.Add([string]$entry.Source); $secretText.Add([string]$entry.Value) }
    }
    $generated = @(foreach ($templateStep in @($phrase.Surfaces[$Surface])) {
        , (Expand-StepPhraseNode -Node $templateStep -Value $slotValue -Type $slotType).Node
    })
    if ($TimeoutSeconds -ge 1) {
        $contract = Get-StepPhraseStepContract
        $written = 0
        $pending = [Collections.Generic.Stack[object]]::new()
        foreach ($step in $generated) { $pending.Push($step) }
        while ($pending.Count -gt 0) {
            $node = $pending.Pop()
            if ($node -isnot [Collections.IDictionary]) { continue }
            if ($node['action'] -is [string] -and $contract.Timeout.Contains($node['action'])) { $node['timeoutSeconds'] = $TimeoutSeconds; $written++ }
            foreach ($nestedKey in 'steps', 'stepsAfterVmRestart') {
                if ($node.Contains($nestedKey)) { foreach ($nested in @($node[$nestedKey])) { $pending.Push($nested) } }
            }
        }
        if ($written -eq 0) {
            throw (New-StepPhraseException -Key 'runner.step_phrase_timeout_unused' -Arguments @{ sentence = "$($phrase.Sentence)"; location = "$Location" })
        }
    }
    if ($null -ne $DescriptionLocalized -and [string]::IsNullOrWhiteSpace($Description)) {
        throw (New-StepPhraseException -Key 'runner.step_sentence_invalid' -Arguments @{ location = "$Location"; reason = 'description-localized'; detail = 'without-description' })
    }
    $label = $found.Masked
    $localized = $null
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        $label = Hide-StepPhraseSecret -Text $Description.Trim() -Secret $secretText.ToArray()
        if ($null -ne $DescriptionLocalized) {
            $localized = [ordered]@{}
            foreach ($locale in $DescriptionLocalized.Keys) {
                $localized[$locale] = Hide-StepPhraseSecret -Text ([string]$DescriptionLocalized[$locale]) -Secret $secretText.ToArray()
            }
        }
    }
    $total = $generated.Count
    for ($at = 0; $at -lt $total; $at++) {
        $suffix = if ($total -gt 1) { " ($($at + 1)/$total)" } else { '' }
        $step = $generated[$at]
        $step['description'] = $label + $suffix
        if ($null -ne $localized) {
            $stepLocalized = [ordered]@{}
            foreach ($locale in $localized.Keys) { $stepLocalized[$locale] = $localized[$locale] + $suffix }
            $step['descriptionLocalized'] = $stepLocalized
        }
        $step['fromStep'] = $found.Masked
        $step
    }
}

function ConvertTo-StepPhraseSlotText {
    <# .SYNOPSIS
        Write one slot value so that the tokenizer reads it back unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $hasWhiteSpace = $false
    foreach ($character in $Value.ToCharArray()) { if ([char]::IsWhiteSpace($character)) { $hasWhiteSpace = $true; break } }
    if ($Value.Length -gt 0 -and -not $hasWhiteSpace -and $Value[0] -cne "'" -and $Value[0] -cne '"') {
        $readBack = $null
        try {
            $readBack = @(ConvertTo-StepPhraseToken -Sentence $Value)
        } catch {
            Write-Verbose "ConvertTo-StepPhraseSlotText: the value is quoted because it does not read back as one word: $($_.Exception.Message)"
        }
        if ($null -ne $readBack -and $readBack.Count -eq 1 -and $readBack[0].Kind -ceq 'word' -and $readBack[0].Value -ceq $Value) { return $Value }
    }
    if ($Value.Contains("'") -and -not $Value.Contains('"')) { return '"' + $Value + '"' }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Format-StepPhraseSentence {
    <# .SYNOPSIS
        Write the sentence of a phrase for one value per slot.
    .DESCRIPTION
        Literals are written as the library spells them; int and key values
        unquoted; text values bare when they read back as one word, else
        quoted. A slot without a value is written '' and is then refused as
        empty when the sentence is resolved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Phrase,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.IDictionary]$Value
    )
    $parts = foreach ($element in $Phrase.Elements) {
        if ($element.Kind -ceq 'literal') { $element.Text; continue }
        $slotValue = if ($Value.Contains($element.Name)) { $Value[$element.Name] } else { $null }
        if ($null -eq $slotValue) { "''"; continue }
        if ($element.Type -in 'int', 'key') { [string]$slotValue; continue }
        ConvertTo-StepPhraseSlotText -Value ([string]$slotValue)
    }
    return (@($parts) -join ' ')
}

Export-ModuleMember -Function ConvertTo-StepPhraseToken, Get-StepPhraseLibrary, Find-StepPhrase, Resolve-StepPhrase, Format-StepPhraseSentence
