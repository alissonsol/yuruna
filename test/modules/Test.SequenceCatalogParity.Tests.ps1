<#PSScriptInfo
.VERSION 2026.11.23
.GUID 426ff71f-7dce-4dfe-a8b5-44f149d582a9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence catalog parity schema
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
    The verbs a runner registers, the two schema enums, the action catalog and
    the documents name the same verbs.
.DESCRIPTION
    A verb is registered in one place and listed in five others: the action enum
    of test/schemas/sequence.schema.yml, the property-name enum of
    test/schemas/actions.schema.yml, the keys of test/sequences/actions.yml, the
    action reference of docs/test-sequences.md and the requirement table of
    docs/test-harness.md and its translation. Nothing validates a sequence
    against its schema at run time, so a list that misses a verb leaves a
    shipped sequence invalid against its own schema with nothing failing. This
    suite holds every list to the registry.

    The registry is read in a fresh process that imports the engine as a runner
    does. The suite then compares against exactly what a runner registers, not
    against throwaway verbs another suite registered in the same session, and
    it leaves that session's registry alone.
#>

BeforeDiscovery {
    $script:AcceptRow = @(
        @{ Name = 'a bare stopVm'; ProbeStep = [ordered]@{ action = 'stopVm' } }
        @{ Name = 'stopVm with its three fields'; ProbeStep = [ordered]@{
                action = 'stopVm'; timeoutSeconds = 120; forceOnTimeout = $true; frameIntervalSeconds = 30 } }
        @{ Name = 'stopVm that saves no frame'; ProbeStep = [ordered]@{ action = 'stopVm'; frameIntervalSeconds = 0 } }
        @{ Name = 'recoverFromSnapshot with an id'; ProbeStep = [ordered]@{ action = 'recoverFromSnapshot'; id = 'baseline' } }
    )
    $script:RejectRow = @(
        @{ Name = 'a text forceOnTimeout'; ProbeStep = [ordered]@{ action = 'stopVm'; forceOnTimeout = 'yes' } }
        @{ Name = 'a zero timeoutSeconds'; ProbeStep = [ordered]@{ action = 'stopVm'; timeoutSeconds = 0 } }
        @{ Name = 'a negative frameIntervalSeconds'; ProbeStep = [ordered]@{ action = 'stopVm'; frameIntervalSeconds = -1 } }
        @{ Name = 'the verb in another letter case'; ProbeStep = [ordered]@{ action = 'stopvm' } }
        @{ Name = 'recoverFromSnapshot without an id'; ProbeStep = [ordered]@{ action = 'recoverFromSnapshot' } }
    )
    $script:HarnessDoc = @(@{ Doc = 'docs/test-harness.md' }, @{ Doc = 'docs/pt-BR/test-harness.md' })
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $exchange = Join-Path $here 'Test.LocalizationExchange.psm1'
    Import-Module $exchange -Force -Global -DisableNameChecking
    Import-Module powershell-yaml -ErrorAction Stop
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $common = Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1'
    Import-Module $common -Force -DisableNameChecking

    function Read-CatalogYaml {
        <#
        .SYNOPSIS
            The YAML file at Path as ordered dictionaries.
        #>
        [CmdletBinding()]
        [OutputType([System.Collections.Specialized.OrderedDictionary])]
        param([Parameter(Mandatory)][string]$Path)
        Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered
    }

    function Compare-VerbCatalog {
        <#
        .SYNOPSIS
            Findings for a catalog whose verb names differ from the registered ones.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Registered,
            [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Listed,
            [Parameter(Mandatory)][string]$Catalog
        )
        $registeredSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($verbName in $Registered) { $null = $registeredSet.Add($verbName) }
        $listedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $firstSeen = [System.Collections.Generic.List[string]]::new()
        foreach ($verbName in $Listed) {
            if ($listedSet.Add($verbName)) {
                $firstSeen.Add($verbName)
            } else {
                "${Catalog}: '$verbName' is listed more than once"
            }
        }
        foreach ($verbName in $Registered) {
            if (-not $listedSet.Contains($verbName)) { "${Catalog}: '$verbName' is registered and not listed" }
        }
        foreach ($verbName in $firstSeen) {
            if (-not $registeredSet.Contains($verbName)) {
                "${Catalog}: '$verbName' is listed and not registered (names are compared case-sensitively)"
            }
        }
    }

    function Get-RegisteredVerb {
        <#
        .SYNOPSIS
            The verbs a runner registers, read in a fresh process that imports the engine.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter(Mandatory)][string]$WorkDir)
        $probe = Join-Path $WorkDir 'registry-probe.ps1'
        $outFile = Join-Path $WorkDir 'registry.json'
        Set-Content -LiteralPath $probe -Encoding utf8 -Value @'
param([Parameter(Mandatory)][string]$EnginePath, [Parameter(Mandatory)][string]$OutFile)
$ErrorActionPreference = 'Stop'
Import-Module $EnginePath -Force -DisableNameChecking
$verbs = foreach ($verbName in @(Get-SequenceActionName)) {
    $entry = Get-SequenceAction -Name $verbName
    [ordered]@{
        name        = [string]$entry.Name
        aliases     = [string[]]@($entry.Aliases)
        hasHandler  = [bool](Test-SequenceActionHasHandler -Name $verbName)
        hostIO      = [string[]]@($entry.HostIORequirement)
        hostCommand = [string[]]@($entry.HostCommandRequirement)
        ocrRequired = [bool]$entry.OcrRequired
    }
}
$record = [ordered]@{
    verbs = @($verbs)
    keys  = [string[]]@((Get-SequenceActionRequirementMap).Keys)
}
[IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $record -Depth 5),
    [Text.UTF8Encoding]::new($false))
exit 0
'@
        $engine = Join-Path $script:RepoRoot 'test/modules/Test.SequenceEngine.psm1'
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path -TimeoutSeconds 120 `
            -Environment @{ NO_COLOR = '1' } -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive',
                '-File', $probe, '-EnginePath', $engine, '-OutFile', $outFile)
        if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0 -or
            -not (Test-Path -LiteralPath $outFile -PathType Leaf)) {
            throw ("the registry probe failed: Started=$($result.Started) TimedOut=$($result.TimedOut) " +
                "ExitCode=$($result.ExitCode)`nstdout: $($result.StdOut)`nstderr: $($result.StdErr)")
        }
        Get-Content -Raw -LiteralPath $outFile | ConvertFrom-Json
    }

    function ConvertTo-ProbeSequenceJson {
        <#
        .SYNOPSIS
            A one-step guest sequence holding Step, as JSON for the schema.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Step)
        [ordered]@{
            description        = 'schema probe'
            keystrokeMechanism = 'gui'
            resource           = [ordered]@{ 'ubuntu.server.26' = @('start.guest.ubuntu.server.26') }
            component          = @($Step)
        } | ConvertTo-Json -Depth 32
    }

    function Get-ActionReferenceSection {
        <#
        .SYNOPSIS
            Each level-3 section under the Action reference heading of a document.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter(Mandatory)][string]$Path)
        $lines = [IO.File]::ReadAllLines($Path)
        $inFence = $false
        $inReference = $false
        $open = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -cmatch '^\s*```') {
                $inFence = -not $inFence
            } elseif (-not $inFence -and $line -cmatch '^#{1,2} ') {
                if ($open) { $open; $open = $null }
                $inReference = $line -ceq '## Action reference'
                continue
            } elseif ($inReference -and -not $inFence -and $line -cmatch '^### (.+?)\s*$') {
                if ($open) { $open }
                $open = [pscustomobject]@{
                    Heading = $Matches[1]
                    Line    = $i + 1
                    Body    = [System.Text.StringBuilder]::new()
                }
                continue
            }
            if ($inReference -and $open) { $null = $open.Body.AppendLine($line) }
        }
        if ($open) { $open }
    }

    function Get-RequirementTableRow {
        <#
        .SYNOPSIS
            Each data row of the verb requirement table of a harness document.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter(Mandatory)][string]$Path)
        $lines = [IO.File]::ReadAllLines($Path)
        $at = [array]::IndexOf($lines, '<a id="42d38664-0013"></a>')
        if ($at -lt 0) { throw "$Path has no requirement table anchor 42d38664-0013" }
        $i = $at + 1
        while ($i -lt $lines.Count -and -not $lines[$i].StartsWith('|')) { $i++ }
        $i += 2
        $token = '`([^`]+)`'
        for (; $i -lt $lines.Count -and $lines[$i].StartsWith('|'); $i++) {
            $cells = @($lines[$i].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
            if ($cells.Count -ne 4) { throw "${Path}:$($i + 1): expected 4 cells, found $($cells.Count)" }
            [pscustomobject]@{
                Line        = $i + 1
                Verb        = [string[]]@([regex]::Matches($cells[0], $token) | ForEach-Object { $_.Groups[1].Value })
                HostIO      = [string[]]@([regex]::Matches($cells[1], $token) | ForEach-Object { $_.Groups[1].Value })
                HostCommand = [string[]]@([regex]::Matches($cells[2], $token) | ForEach-Object { $_.Groups[1].Value })
                Ocr         = $cells[3]
            }
        }
    }

    $script:Registry = Get-RegisteredVerb -WorkDir $TestDrive
    [string[]]$script:Canonical = @($script:Registry.verbs | ForEach-Object { [string]$_.name })
    [string[]]$script:Alias = @($script:Registry.verbs | ForEach-Object { @($_.aliases) } |
        Where-Object { $_ })
    [string[]]$script:Registered = @($script:Canonical) + @($script:Alias)
    $schemaPath = Join-Path $script:RepoRoot 'test/schemas/sequence.schema.yml'
    $script:SequenceSchema = Read-CatalogYaml -Path $schemaPath
    $script:SequenceSchemaJson = $script:SequenceSchema | ConvertTo-Json -Depth 32
}

Describe 'the verb registry a runner process loads' {
    It 'gives every registered verb a handler and every alias a requirement entry' {
        Assert-True (@($script:Registry.verbs).Count -gt 0) 'the fresh process registered no verb'
        $findings = @()
        foreach ($verb in @($script:Registry.verbs)) {
            if (-not $verb.hasHandler) { $findings += "registry: '$($verb.name)' has no handler" }
        }
        $seen = @{}
        foreach ($verbName in $script:Registered) {
            $lower = $verbName.ToLowerInvariant()
            if ($seen.ContainsKey($lower)) {
                $findings += "registry: '$verbName' and '$($seen[$lower])' differ only in letter case"
            } else {
                $seen[$lower] = $verbName
            }
        }
        $findings += @(Compare-VerbCatalog -Registered $script:Registered -Listed ([string[]]@($script:Registry.keys)) -Catalog 'requirement map')
        Assert-NoFinding $findings 'every registered verb runs a handler, and the capability gate reads a requirement entry for every name a sequence may use'
    }
}

Describe 'verb names agree across the catalogs' {
    It 'reports a missing, an unregistered, a case-variant and a repeated name' {
        $result = @(Compare-VerbCatalog -Registered 'stopVm', 'typeAndEnter' -Listed 'stopvm', 'typeAndEnter', 'typeAndEnter', 'ghost' -Catalog 'fixture')
        Assert-Equal 4 $result.Count ("the comparison gave: " + ($result -join ' | '))
        foreach ($expected in @(
                "fixture: 'ghost' is listed and not registered (names are compared case-sensitively)",
                "fixture: 'stopvm' is listed and not registered (names are compared case-sensitively)",
                "fixture: 'stopVm' is registered and not listed",
                "fixture: 'typeAndEnter' is listed more than once")) {
            Assert-True ($result -ccontains $expected) "missing finding: $expected"
        }
    }

    It 'lists exactly the registered names in the action enum of sequence.schema.yml' {
        [string[]]$enum = @($script:SequenceSchema['$defs']['actionStep']['properties']['action']['enum'])
        Assert-NoFinding @(Compare-VerbCatalog -Registered $script:Registered -Listed $enum -Catalog 'sequence.schema.yml action enum') `
            'a sequence step names its verb through this enum, so a registered verb it lacks makes a working sequence invalid'
    }

    It 'lists exactly the registered names in the property-name enum of actions.schema.yml' {
        $catalogSchema = Read-CatalogYaml -Path (Join-Path $script:RepoRoot 'test/schemas/actions.schema.yml')
        [string[]]$enum = @($catalogSchema['properties']['actions']['propertyNames']['enum'])
        Assert-NoFinding @(Compare-VerbCatalog -Registered $script:Registered -Listed $enum -Catalog 'actions.schema.yml property-name enum') `
            'the catalog schema names the same verbs as the sequence schema and the registry'
    }

    It 'describes exactly the registered names in actions.yml, and each alias entry names its verb' {
        $path = Join-Path $script:RepoRoot 'test/sequences/actions.yml'
        $text = Get-Content -Raw -LiteralPath $path
        [string[]]$textKey = @([regex]::Matches($text, '(?m)^  ([A-Za-z][A-Za-z0-9]*):') | ForEach-Object { $_.Groups[1].Value })
        $entries = (Read-CatalogYaml -Path $path)['actions']
        $findings = @()
        if ($textKey.Count -ne $entries.Keys.Count) {
            $findings += "actions.yml: the text holds $($textKey.Count) keys and the parser read $($entries.Keys.Count); two keys differ only in letter case"
        }
        $findings += @(Compare-VerbCatalog -Registered $script:Registered -Listed $textKey -Catalog 'actions.yml')
        foreach ($verb in @($script:Registry.verbs)) {
            foreach ($alias in @($verb.aliases | Where-Object { $_ })) {
                if ($textKey -ccontains $alias -and -not ([string]$entries[$alias]).Contains([string]$verb.name)) {
                    $findings += "actions.yml: the entry of alias '$alias' does not name its verb '$($verb.name)'"
                }
            }
        }
        Assert-NoFinding $findings 'every registered name has one catalog entry, and an alias entry points the author to its verb'
    }

    It 'keeps actions.yml valid against actions.schema.yml' {
        $catalogJson = Read-CatalogYaml -Path (Join-Path $script:RepoRoot 'test/sequences/actions.yml') | ConvertTo-Json -Depth 32
        $schemaJson = Read-CatalogYaml -Path (Join-Path $script:RepoRoot 'test/schemas/actions.schema.yml') | ConvertTo-Json -Depth 32
        Assert-Null (Get-YurunaJsonSchemaError -Json $catalogJson -Schema $schemaJson) 'actions.yml is described by actions.schema.yml'
    }

    It 'names only enum verbs in the per-verb branches of sequence.schema.yml' {
        [string[]]$enum = @($script:SequenceSchema['$defs']['actionStep']['properties']['action']['enum'])
        $named = [System.Collections.Generic.List[string]]::new()
        foreach ($branch in @($script:SequenceSchema['$defs']['actionStep']['allOf'])) {
            if ($branch -isnot [System.Collections.IDictionary] -or -not $branch.Contains('if')) { continue }
            $condition = $branch['if']
            if ($condition -isnot [System.Collections.IDictionary] -or -not $condition.Contains('properties')) { continue }
            $properties = $condition['properties']
            if ($properties -isnot [System.Collections.IDictionary] -or -not $properties.Contains('action')) { continue }
            $action = $properties['action']
            if ($action.Contains('const')) { $named.Add([string]$action['const']) }
            if ($action.Contains('enum')) { foreach ($verbName in @($action['enum'])) { $named.Add([string]$verbName) } }
        }
        Assert-True ($named.Count -ge 20) "only $($named.Count) verb names were read from the per-verb branches"
        $findings = foreach ($verbName in $named) {
            if (-not ($enum -ccontains $verbName)) { "sequence.schema.yml: a branch names '$verbName', which the action enum lacks" }
        }
        Assert-NoFinding @($findings) 'a branch for a verb the enum lacks can never apply'
    }
}

Describe 'the framework sequences use only what the schema accepts' {
    It 'validates every guest sequence under test/sequences against sequence.schema.yml' {
        $checked = 0
        $findings = @()
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test/sequences') -Filter '*.yml' -File) {
            $parsed = Read-CatalogYaml -Path $file.FullName
            if ($parsed -isnot [System.Collections.IDictionary]) { continue }
            if (-not ($parsed.Contains('resource') -or $parsed.Contains('keystrokeMechanism'))) { continue }
            $checked++
            $schemaError = Get-YurunaJsonSchemaError -Json ($parsed | ConvertTo-Json -Depth 32) -Schema $script:SequenceSchemaJson
            if (-not $schemaError) { continue }
            $finding = "$($file.Name): $schemaError"
            $pointer = [regex]::Match($schemaError, "at '/(component|workload)/(\d+)")
            if ($pointer.Success) {
                $step = @($parsed[$pointer.Groups[1].Value])[[int]$pointer.Groups[2].Value]
                if ($step -is [System.Collections.IDictionary] -and $step.Contains('action')) {
                    $finding += " (step action '$($step['action'])')"
                }
            }
            $findings += $finding
        }
        Assert-True ($checked -gt 0) 'no guest sequence was found under test/sequences'
        Assert-NoFinding $findings 'a shipped sequence must be valid against the schema it declares'
    }
}

Describe 'the sequence schema types the stopVm and recoverFromSnapshot fields' {
    It 'accepts <Name>' -ForEach $script:AcceptRow {
        Assert-Null (Get-YurunaJsonSchemaError -Json (ConvertTo-ProbeSequenceJson -Step $ProbeStep) -Schema $script:SequenceSchemaJson) `
            'the schema accepts this step'
    }

    It 'rejects <Name>' -ForEach $script:RejectRow {
        Assert-NotNull (Get-YurunaJsonSchemaError -Json (ConvertTo-ProbeSequenceJson -Step $ProbeStep) -Schema $script:SequenceSchemaJson) `
            'the schema rejects this step'
    }
}

Describe 'the documents name every verb' {
    It 'gives every canonical verb one level-3 heading under Action reference, and no other one-word heading there' {
        $sections = @(Get-ActionReferenceSection -Path (Join-Path $script:RepoRoot 'docs/test-sequences.md'))
        [string[]]$heading = @($sections | Where-Object { $_.Heading -cmatch '^[A-Za-z][A-Za-z0-9]*$' } | ForEach-Object { $_.Heading })
        Assert-NoFinding @(Compare-VerbCatalog -Registered $script:Canonical -Listed $heading -Catalog 'docs/test-sequences.md action reference') `
            'each verb is documented once, in the action reference'
    }

    It 'names each alias in the section of the verb it stands for' {
        $sections = @(Get-ActionReferenceSection -Path (Join-Path $script:RepoRoot 'docs/test-sequences.md'))
        $findings = @()
        foreach ($verb in @($script:Registry.verbs)) {
            foreach ($alias in @($verb.aliases | Where-Object { $_ })) {
                $section = @($sections | Where-Object { $_.Heading -ceq [string]$verb.name }) | Select-Object -First 1
                if (-not $section) {
                    $findings += "docs/test-sequences.md: no section for '$($verb.name)', the verb of alias '$alias'"
                } elseif (-not $section.Body.ToString().Contains("``$alias``")) {
                    $findings += "docs/test-sequences.md: the section of '$($verb.name)' does not name its alias '$alias'"
                }
            }
        }
        Assert-NoFinding $findings 'an author who meets an alias in a sequence finds it in the section of its verb'
    }

    It 'matches what each verb registers in the requirement table of <Doc>' -ForEach $script:HarnessDoc {
        $rows = @(Get-RequirementTableRow -Path (Join-Path $script:RepoRoot $Doc))
        [string[]]$listed = @($rows | ForEach-Object { @($_.Verb) })
        $findings = @(Compare-VerbCatalog -Registered $script:Canonical -Listed $listed -Catalog $Doc)
        $byName = @{}
        foreach ($verb in @($script:Registry.verbs)) { $byName[[string]$verb.name] = $verb }
        $yes = @('yes', 'sim')
        $no = @('no', "n`u{00E3}o")
        foreach ($row in $rows) {
            if (-not ($yes -ccontains $row.Ocr -or $no -ccontains $row.Ocr)) {
                $findings += "${Doc}:$($row.Line): OCR cell '$($row.Ocr)' is none of yes, sim, no, n`u{00E3}o"
            }
            foreach ($verbName in @($row.Verb)) {
                if (-not ($script:Canonical -ccontains $verbName)) { continue }
                $verb = $byName[$verbName]
                $tableIO = (@($row.HostIO) | Sort-Object -CaseSensitive) -join ', '
                $registeredIO = (@($verb.hostIO | Where-Object { $_ }) | Sort-Object -CaseSensitive) -join ', '
                if ($tableIO -cne $registeredIO) {
                    $findings += "${Doc}:$($row.Line): '$verbName' lists host I/O '$tableIO'; it registers '$registeredIO'"
                }
                $tableCommand = (@($row.HostCommand) | Sort-Object -CaseSensitive) -join ', '
                $registeredCommand = (@($verb.hostCommand | Where-Object { $_ }) | Sort-Object -CaseSensitive) -join ', '
                if ($tableCommand -cne $registeredCommand) {
                    $findings += "${Doc}:$($row.Line): '$verbName' lists host commands '$tableCommand'; it registers '$registeredCommand'"
                }
                if (($yes -ccontains $row.Ocr) -ne [bool]$verb.ocrRequired -and ($yes -ccontains $row.Ocr -or $no -ccontains $row.Ocr)) {
                    $findings += "${Doc}:$($row.Line): '$verbName' shows OCR '$($row.Ocr)'; it registers OcrRequired $($verb.ocrRequired)"
                }
            }
        }
        Assert-NoFinding $findings 'the requirement table is how an operator learns what each verb needs from a host'
    }
}

Describe 'the phrase library stays inside the catalogs' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.SequenceResolve.psm1') -Force -Global -DisableNameChecking
        $script:PhraseLibrary = Get-SequencePhraseLibrary
    }

    It 'uses only canonical registered verbs in the templates of test/sequences/_phrases.yml' {
        $read = 0
        $findings = @()
        foreach ($phrase in @($script:PhraseLibrary.Phrases)) {
            foreach ($surfaceName in $phrase.Surfaces.Keys) {
                $pending = [System.Collections.Generic.Stack[object]]::new()
                foreach ($templateStep in @($phrase.Surfaces[$surfaceName])) { $pending.Push($templateStep) }
                while ($pending.Count -gt 0) {
                    $templateStep = $pending.Pop()
                    $action = [string]$templateStep['action']
                    $read++
                    if (-not ($script:Canonical -ccontains $action)) {
                        $findings += "$($phrase.Id) ($surfaceName): '$action' is not a canonical registered verb"
                    }
                    foreach ($nestedKey in 'steps', 'stepsAfterVmRestart') {
                        if ($templateStep.Contains($nestedKey)) { foreach ($nested in @($templateStep[$nestedKey])) { $pending.Push($nested) } }
                    }
                }
            }
        }
        Assert-True ($read -ge 10) "only $read template actions were read"
        Assert-NoFinding $findings 'a phrase generates the verbs a runner registers, under their canonical names'
    }

    It 'names every sentence of test/sequences/_phrases.yml in docs/test-sequences.md' {
        $document = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'docs/test-sequences.md'))
        $findings = @(foreach ($phrase in @($script:PhraseLibrary.Phrases)) {
            if (-not $document.Contains('`' + $phrase.Sentence + '`')) { "docs/test-sequences.md does not name the sentence '$($phrase.Sentence)' ($($phrase.Id))" }
        })
        Assert-NoFinding $findings 'an author learns the vocabulary from the document'
    }
}
