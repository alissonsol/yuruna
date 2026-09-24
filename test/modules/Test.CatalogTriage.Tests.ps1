<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42ca1dd9-3a18-467e-94a5-26a3b73501e2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization triage catalog classification pester
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
    Keep the triage honest about what it knows and about what it changes.
.DESCRIPTION
    The triage exists so a conversion metric can move. That makes two failure
    modes expensive in opposite directions.

    The first is a confident wrong answer. Calling a stack frame or a compared
    protocol value operator-facing puts it in front of a reader in every
    language; so the classifier only promotes on a positive signal, and the
    cases below pin both directions -- a thrown message stays internal, a label
    assigned to a display property becomes a conversion.

    The second is a record that quietly changes under somebody. A person who
    resolves a candidate by hand has spent the expensive part of this work, and
    a classifier that reverses that on the next run makes the queue unfinishable.
    So the manifest is additive, a recorded decision outranks the rules, an
    unchanged tree produces identical bytes, and no message a translator may
    already hold is ever rewritten.

    The fixtures are a throwaway repository under TestDrive with its own source,
    catalogs and manifest, because a suite that wrote into globalization/ would
    be editing the artifact the release gates read.

    Run: Invoke-Pester -Path test/modules/Test.CatalogTriage.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Invoke-CatalogTriage.ps1'
$script:InventoryTool = Join-Path $script:RepoRoot 'tools/Invoke-DomainInventory.ps1'
$script:InventoryPath = Join-Path $script:RepoRoot 'globalization/manifests/domain-inventory.json'

# The fixture sources. Each literal below is here for one verdict, so a rule
# that stops firing fails a named case instead of moving a total by one.
$script:FixtureJs = @'
// A comment with an apostrophe that must not shift the scan.
function render(root) {
  var banner = Y.el('span', { text: 'Every host in the pool is online.' });
  root.textContent = 'The cycle finished with no findings.';
  console.log('the beacon returned no rows for this window');
  if (root.id === 'the identifier compared against a protocol value') { return banner; }
  throw new Error('the status document could not be parsed at all');
}
'@

$script:FixturePs = @'
function Test-Fixture {
    [CmdletBinding()]
    param([string]$Name)
    Write-Verbose 'the worker did not report a heartbeat in time'
    if ($Name -match 'a pattern that only a machine reads') { return }
    $unclassified = 'Pick a host from the list and try the cycle again.'
    Write-Output 'The operator can retry after repairing the connection.'
    $query = 'SELECT name FROM connections WHERE state = 1'
    $command = 'sudo systemctl restart yuruna-service'
    $finding = @{ description = 'Repair the missing deployment credentials.' }
    Write-Output (Format-CatalogMessage -Key 'fixture.status' -Arguments @{ reason = 'The request still needs operator attention.' })
    throw 'the configured reference host is unreachable from here'
}
'@

function New-TriageFixture {
    <#
    .SYNOPSIS
        A throwaway repository holding one file in each scanned language.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a disposable fixture tree under TestDrive; there is nothing for an operator to confirm.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    foreach ($relative in @('test/status', 'test/modules')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $Path $relative) -Force
    }
    # Git decides which files are in scope, so the fixture needs to be a work
    # tree even though nothing is ever committed in it.
    & git -C $Path init --quiet
    [IO.File]::WriteAllText((Join-Path $Path 'test/status/fixture.js'), $script:FixtureJs)
    [IO.File]::WriteAllText((Join-Path $Path 'test/modules/Test.Fixture.psm1'), $script:FixturePs)
    return $Path
}

function Invoke-Triage {
    <#
    .SYNOPSIS
        Runs the tool out of process and returns its exit code with its output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argument)

    $output = & pwsh -NoProfile -File $script:Tool @Argument 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Get-TriageManifest {
    <#
    .SYNOPSIS
        The recorded manifest of a fixture repository.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)))
}

function Get-TriageCandidate {
    <#
    .SYNOPSIS
        The recorded entry for one exact literal, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Text)

    return @($Manifest.candidates | Where-Object { [string]$_.text -ceq $Text }) | Select-Object -First 1
}
}

Describe 'the classifier answers in both directions' {

    BeforeAll {
        $script:Fixture = New-TriageFixture -Path (Join-Path $TestDrive 'verdicts')
        $script:FixtureManifest = Join-Path $script:Fixture 'globalization/manifests/candidate-triage.json'
        $script:Run = Invoke-Triage -Argument @('-Root', $script:Fixture, '-Update', '-Quiet')
        $script:Doc = Get-TriageManifest -Path $script:FixtureManifest
    }

    It 'records a manifest this repository can read back' {
        Assert-Equal -Expected 0 -Actual $script:Run.ExitCode -Because $script:Run.Output
        Assert-StringEqual -Expected 'yuruna.candidate-triage/v1' -Actual $script:Doc.schema `
            'the manifest schema id changed without a migration'
        Assert-True (@($script:Doc.candidates).Count -gt 0) 'the triage recorded no candidate at all'
    }

    It 'separates developer diagnostics from operator output and failure prose' {
        # The two verdicts the whole tool turns on. A wrong internal leaves one
        # sentence untranslated; a wrong convert ships a defect report to a
        # reader in every language the product supports.
        $findings = @()
        foreach ($case in @(
                @{ Text = 'the configured reference host is unreachable from here'; Want = 'convert'; Rule = 'exception-text' }
                @{ Text = 'the status document could not be parsed at all'; Want = 'convert'; Rule = 'exception-text' }
                @{ Text = 'the worker did not report a heartbeat in time'; Want = 'internal'; Rule = 'diagnostic-stream' }
                @{ Text = 'the beacon returned no rows for this window'; Want = 'internal'; Rule = 'diagnostic-stream' }
                @{ Text = 'a pattern that only a machine reads'; Want = 'internal'; Rule = 'regex-body' }
                @{ Text = 'the identifier compared against a protocol value'; Want = 'internal'; Rule = 'comparison-operand' }
                @{ Text = 'Every host in the pool is online.'; Want = 'convert'; Rule = 'display-property' }
                @{ Text = 'The cycle finished with no findings.'; Want = 'convert'; Rule = 'display-property' }
                @{ Text = 'The operator can retry after repairing the connection.'; Want = 'convert'; Rule = 'operator-stream' }
                @{ Text = 'Repair the missing deployment credentials.'; Want = 'convert'; Rule = 'display-result' }
                @{ Text = 'The request still needs operator attention.'; Want = 'convert'; Rule = 'operator-stream' }
                @{ Text = 'SELECT name FROM connections WHERE state = 1'; Want = 'internal'; Rule = 'sql-statement' }
                @{ Text = 'sudo systemctl restart yuruna-service'; Want = 'internal'; Rule = 'command-source' })) {
            $entry = Get-TriageCandidate -Manifest $script:Doc -Text $case.Text
            if (-not $entry) { $findings += "'$($case.Text)' was not triaged at all"; continue }
            if ([string]$entry.disposition -cne $case.Want) {
                $findings += "'$($case.Text)' -> $($entry.disposition), expected $($case.Want)"
            }
            if ([string]$entry.rule -cne $case.Rule) {
                $findings += "'$($case.Text)' fired rule '$($entry.rule)', expected '$($case.Rule)'"
            }
        }
        Assert-NoFinding $findings 'the classifier no longer separates shipped text from internal text'
    }

    It 'leaves a sentence it cannot place unexplained rather than guessing' {
        $entry = Get-TriageCandidate -Manifest $script:Doc -Text 'Pick a host from the list and try the cycle again.'
        Assert-NotNull $entry 'the ordinary operator sentence was not triaged'
        Assert-StringEqual -Expected 'unexplained' -Actual $entry.disposition `
            'a sentence with no positive signal was promoted on a hunch'
        Assert-StringEqual -Expected '' -Actual $entry.rule 'an unexplained candidate claims a rule fired'
    }

    It 'explains every internal verdict in words' {
        # A count by rule says how often the classifier fired and never lets
        # anybody check whether it was right.
        $findings = @()
        foreach ($entry in @($script:Doc.candidates | Where-Object { $_.disposition -eq 'internal' })) {
            if (-not $entry.rule) { $findings += "internal '$($entry.text)' names no rule" }
            if (([string]$entry.reason).Trim().Length -lt 10) {
                $findings += "internal '$($entry.text)' carries no readable reason"
            }
        }
        Assert-NoFinding $findings 'an internal verdict is unreviewable'
    }

    It 'never writes to the sources it read' {
        $before = @{}
        foreach ($relative in @('test/status/fixture.js', 'test/modules/Test.Fixture.psm1')) {
            $before[$relative] = (Get-FileHash -LiteralPath (Join-Path $script:Fixture $relative) -Algorithm SHA256).Hash
        }
        $run = Invoke-Triage -Argument @('-Root', $script:Fixture, '-Update', '-EmitCatalog', '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        $findings = @($before.Keys | Where-Object {
                (Get-FileHash -LiteralPath (Join-Path $script:Fixture $_) -Algorithm SHA256).Hash -ne $before[$_]
            } | ForEach-Object { "the triage rewrote $_" })
        Assert-NoFinding $findings 'the triage is editing product source, which is a separate conversion step'
    }
}

Describe 'the record is additive and a decision outranks the rules' {

    BeforeAll {
        $script:Additive = New-TriageFixture -Path (Join-Path $TestDrive 'additive')
        $script:AdditiveManifest = Join-Path $script:Additive 'globalization/manifests/candidate-triage.json'
        $null = Invoke-Triage -Argument @('-Root', $script:Additive, '-Update', '-Quiet')
    }

    It 'writes identical bytes when nothing in the tree changed' {
        $first = [IO.File]::ReadAllBytes($script:AdditiveManifest)
        $run = Invoke-Triage -Argument @('-Root', $script:Additive, '-Update', '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        $second = [IO.File]::ReadAllBytes($script:AdditiveManifest)
        Assert-Equal -Expected $first.Length -Actual $second.Length `
            'a second run over an unchanged tree produced a different manifest length'
        Assert-True ([Linq.Enumerable]::SequenceEqual($first, $second)) `
            'a second run over an unchanged tree produced different bytes, so nothing downstream can trust a diff'
    }

    It 'keeps a recorded decision and lets it overrule the classifier' {
        # The expensive part of this work is a person reading a sentence and
        # deciding. Reversing that on the next run makes the queue unfinishable.
        $doc = Get-TriageManifest -Path $script:AdditiveManifest
        $entry = Get-TriageCandidate -Manifest $doc -Text 'the worker did not report a heartbeat in time'
        Assert-StringEqual -Expected 'internal' -Actual $entry.disposition 'the fixture case is not the one being overruled'

        $run = Invoke-Triage -Argument @('-Root', $script:Additive, '-Update', '-Quiet',
            '-Decide', [string]$entry.id, '-As', 'convert', '-Reason', 'the transcript shows this to an operator')
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output

        $after = Get-TriageManifest -Path $script:AdditiveManifest
        $decided = Get-TriageCandidate -Manifest $after -Text 'the worker did not report a heartbeat in time'
        Assert-StringEqual -Expected 'convert' -Actual $decided.disposition `
            'the classifier overruled a decision a person recorded'
        Assert-StringEqual -Expected 'recorded-decision' -Actual $decided.rule 'the decision is not named as the reason'
        Assert-Match -Pattern 'transcript' -Actual ([string]$decided.reason) `
            "the person's own reason was replaced by a machine one"

        # And it survives a run that was not told about it again.
        $null = Invoke-Triage -Argument @('-Root', $script:Additive, '-Update', '-Quiet')
        $later = Get-TriageManifest -Path $script:AdditiveManifest
        $survivor = Get-TriageCandidate -Manifest $later -Text 'the worker did not report a heartbeat in time'
        Assert-StringEqual -Expected 'convert' -Actual $survivor.disposition `
            'the recorded decision was dropped by the next ordinary run'
        Assert-True ([bool]$later.decisions.PSObject.Properties[[string]$entry.id]) `
            'the decision record itself disappeared from the manifest'
    }

    It 'refuses a decision it cannot record or explain' {
        $findings = @()
        foreach ($case in @(
                @{ Argument = @('-Decide', 'abc123', '-As', 'internal', '-Reason', 'x'); Why = 'a decision without -Update' }
                @{ Argument = @('-Update', '-Decide', 'abc123', '-As', 'internal'); Why = 'a decision without a reason' }
                @{ Argument = @('-Update', '-Decide', 'abc123', '-Reason', 'x'); Why = 'a decision without a disposition' })) {
            $run = Invoke-Triage -Argument (@('-Root', $script:Additive, '-Quiet') + $case.Argument)
            if ($run.ExitCode -ne 2) { $findings += "$($case.Why) was accepted (exit $($run.ExitCode))" }
        }
        Assert-NoFinding $findings 'an unreviewable decision can reach the manifest'
    }

    It 'adds catalog messages without rewriting one that already exists' {
        $catalogRoot = Join-Path $script:Additive 'globalization/catalogs/en-US'
        $run = Invoke-Triage -Argument @('-Root', $script:Additive, '-Update', '-EmitCatalog', '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        $emitted = Join-Path $catalogRoot 'status.ui.json'
        Assert-True (Test-Path -LiteralPath $emitted -PathType Leaf) 'no catalog was emitted for a converted domain'

        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($emitted))
        $keys = @($catalog.messages.PSObject.Properties.Name)
        Assert-True ($keys.Count -ge 1) 'the emitted catalog holds no message'
        $reviewed = $keys[0]

        # What a reviewer does next: rewrite the machine's wording, and add a
        # key of their own. Neither may be touched again.
        $catalog.messages.$reviewed.message = 'A reviewer rewrote this sentence.'
        $catalog.messages | Add-Member -NotePropertyName 'status.ui.kept_by_hand' -NotePropertyValue ([pscustomobject]@{
                message = 'Written by hand and owned by a person.'; description = 'A message the triage did not propose.'
                lifecycle = 'active'
            })
        [IO.File]::WriteAllText($emitted, ((ConvertTo-Json -InputObject $catalog -Depth 8) -replace "`r`n", "`n").TrimEnd() + "`n",
            [Text.UTF8Encoding]::new($false))

        # A new operator-facing label appears in the tree.
        [IO.File]::WriteAllText((Join-Path $script:Additive 'test/status/late.js'),
            "var later = Y.el('p', { text: 'A label that arrived after the first pass.' });`n")
        $second = Invoke-Triage -Argument @('-Root', $script:Additive, '-Update', '-EmitCatalog', '-Quiet')
        Assert-Equal -Expected 0 -Actual $second.ExitCode -Because $second.Output

        $after = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($emitted))
        Assert-StringEqual -Expected 'A reviewer rewrote this sentence.' -Actual $after.messages.$reviewed.message `
            'the triage overwrote wording a reviewer owns'
        Assert-NotNull $after.messages.'status.ui.kept_by_hand' 'the triage removed a key it did not author'
        $afterKeys = @($after.messages.PSObject.Properties.Name)
        Assert-NoFinding (@($keys | Where-Object { $afterKeys -notcontains $_ } | ForEach-Object { "key removed: $_" })) `
            'emission is not additive'
        Assert-True ($afterKeys.Count -gt $keys.Count + 1) 'the late operator label never reached the catalog'
    }
}

Describe 'the gate reports what is left' {

    BeforeAll {
        $script:Gate = New-TriageFixture -Path (Join-Path $TestDrive 'gate')
        $script:GateManifest = Join-Path $script:Gate 'globalization/manifests/candidate-triage.json'
    }

    It 'fails while a candidate is unexplained and passes once none is' {
        $before = Invoke-Triage -Argument @('-Root', $script:Gate, '-Quiet')
        Assert-Equal -Expected 1 -Actual $before.ExitCode `
            'a tree with an unexplained candidate passed the gate, so the metric can never mean anything'
        Assert-Match -Pattern 'unexplained' -Actual $before.Output 'the gate does not say what is missing'

        $null = Invoke-Triage -Argument @('-Root', $script:Gate, '-Update', '-Quiet')
        $doc = Get-TriageManifest -Path $script:GateManifest
        $open = @($doc.candidates | Where-Object { $_.disposition -eq 'unexplained' } | ForEach-Object { [string]$_.id })
        Assert-True ($open.Count -ge 1) 'the fixture left nothing to resolve'
        $resolve = @('-Root', $script:Gate, '-Update', '-Quiet', '-As', 'internal',
            '-Reason', 'a runner transcript line, not shipped interface text', '-Decide') + $open
        $run = Invoke-Triage -Argument $resolve
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output

        $after = Invoke-Triage -Argument @('-Root', $script:Gate, '-Quiet')
        Assert-Equal -Expected 0 -Actual $after.ExitCode `
            -Because "every candidate has a disposition and the gate still fails:`n$($after.Output)"
    }

    It 'writes nothing when asked what it would do' {
        $scratch = Join-Path $TestDrive 'whatif-triage.json'
        $run = Invoke-Triage -Argument @('-Root', $script:Gate, '-Domain', 'status-ui', '-Update',
            '-OutputPath', $scratch, '-WhatIf', '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        Assert-False (Test-Path -LiteralPath $scratch) '-WhatIf wrote the manifest it was only asked about'
    }

    It 'refuses to narrow the shared manifest to one domain' {
        # A manifest holding one domain would pass the gate for every other
        # domain in the tree, which is worse than no manifest at all.
        $run = Invoke-Triage -Argument @('-Root', $script:Gate, '-Domain', 'status-ui', '-Update', '-Quiet')
        Assert-Equal -Expected 2 -Actual $run.ExitCode 'a single-domain run overwrote the shared manifest'
        Assert-Match -Pattern 'OutputPath' -Actual $run.Output 'the refusal does not say what to do instead'
    }

    It 'names an unknown domain instead of reporting an empty tree' {
        $run = Invoke-Triage -Argument @('-Root', $script:Gate, '-Domain', 'no-such-domain', '-Quiet')
        Assert-Equal -Expected 2 -Actual $run.ExitCode 'a misspelled domain reported a clean triage'
    }
}

Describe 'the candidate set is the inventory set' {

    It 'reuses the inventory definitions instead of restating them' {
        # Two definitions of "candidate" agree until somebody edits one of them,
        # and then one number is reported and a different one is closed.
        $findings = @()
        foreach ($name in @('Test-IsProseCandidate', 'Get-ScannedStringLiteral', 'Test-IsSentenceFragment')) {
            if (Get-YurunaTestFunctionAst -Path $script:Tool -Name $name) {
                $findings += "the triage defines its own $name instead of reusing the inventory's"
            }
            if (-not (Get-YurunaTestFunctionAst -Path $script:InventoryTool -Name $name)) {
                $findings += "the inventory no longer defines $name, which the triage lifts"
            }
        }
        Assert-NoFinding $findings 'the candidate definition has forked'

        $source = [IO.File]::ReadAllText($script:Tool)
        Assert-Match -Pattern 'Invoke-DomainInventory\.ps1' -Actual $source `
            'the triage does not read the inventory it must agree with'
    }

    It 'counts in each domain exactly what the recorded inventory counts' {
        $inventory = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:InventoryPath))
        $findings = @()
        foreach ($name in @('notification', 'status-ui', 'pool-aggregator')) {
            $scratch = Join-Path $TestDrive "inventory-$name.json"
            $run = Invoke-Triage -Argument @('-Domain', $name, '-Update', '-OutputPath', $scratch, '-Quiet')
            if ($run.ExitCode -ne 0) { $findings += "${name}: the triage failed: $($run.Output)"; continue }
            $row = @(Get-TriageManifest -Path $scratch).domains | Where-Object { [string]$_.domain -ceq $name }
            $recorded = @($inventory.domains | Where-Object { [string]$_.domain -ceq $name })[0]
            if ([int]$row.occurrences -ne [int]$recorded.candidates) {
                $findings += "${name}: triaged $($row.occurrences) literal(s), the inventory records $($recorded.candidates)"
            }
            if ([int]$row.files -ne [int]$recorded.files) {
                $findings += "${name}: triaged $($row.files) file(s), the inventory records $($recorded.files)"
            }
            if ([int]$row.candidates -ne ([int]$row.convert + [int]$row.internal + [int]$row.unexplained)) {
                $findings += "${name}: the dispositions do not add up to the candidate count"
            }
        }
        Assert-NoFinding $findings 'the triage and the inventory disagree about what the tree holds'
    }

    It 'names the domains it does not triage rather than dropping them' {
        $scratch = Join-Path $TestDrive 'scope-triage.json'
        $run = Invoke-Triage -Argument @('-Domain', 'notification', '-Update', '-OutputPath', $scratch, '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        $doc = Get-TriageManifest -Path $scratch
        $named = @($doc.scope.untriaged | ForEach-Object { [string]$_.domain })
        foreach ($name in @('project-config', 'project-docs')) {
            Assert-True ($named -ccontains $name) `
                "domain '$name' is neither triaged nor named as out of scope, so its wording is invisible here"
        }
        foreach ($row in @($doc.scope.untriaged)) {
            Assert-True (([string]$row.reason).Trim().Length -gt 20) `
                "domain '$($row.domain)' is excluded with no stated reason"
        }
    }
}
