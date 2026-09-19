<#PSScriptInfo
.VERSION 2026.09.18
.GUID 421e2d93-7e74-4a5d-90d5-4a730e5dc48f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization terminology style-guide approval pester
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
    Prove terminology sources cannot drift, translate protocol literals, or
    claim human review without evidence.

    Run: Invoke-Pester -Path test/modules/Test.Terminology.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.ApprovalDigest.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Test-Terminology.ps1'
$script:DocTool = Join-Path $script:RepoRoot 'tools/Test-DocTranslation.ps1'
$script:PowerShell = (Get-Process -Id $PID).Path

# The document recorder, pointed at a throwaway copy of the record. The English
# sources it hashes are the real ones -- only the file it would rewrite is
# disposable, so a refused run and an accepted one are both observable without
# touching the tracked manifest.
function Invoke-DocTranslationAccept {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][ValidateSet('reviewed', 'draft')][string]$Status
    )
    $arguments = @('-NoProfile', '-File', $script:DocTool, '-AcceptReview', '-Status', $Status,
        '-Path', 'docs/operator.md', '-Manifest', $Manifest, '-Quiet')
    $output = & $script:PowerShell @arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}

function New-TerminologyFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable terminology tree under TestDrive.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $root = Join-Path $TestDrive $Name
    $paths = @(
        'docs/definition.md',
        'tools/githooks/pre-commit',
        'globalization/manifests/doc-translations.json',
        'globalization/schema/terminology.schema.json',
        'globalization/schema/style-guide.schema.json',
        'globalization/terminology/pt-BR.terms.json',
        'globalization/terminology/pt-BR.style-guide.json',
        'VERSION'
    )
    foreach ($relative in $paths) {
        $target = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $relative) -Destination $target
    }
    return $root
}

function Read-FixtureJson {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Root $RelativePath)))
}

function Write-FixtureJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates a disposable JSON fixture under TestDrive.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][pscustomobject]$Value
    )
    $json = ConvertTo-Json -InputObject $Value -Depth 20
    [IO.File]::WriteAllText((Join-Path $Root $RelativePath), "$json`n", [Text.UTF8Encoding]::new($false))
}

function Get-FileHashText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Update-FixtureStyleHash {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Keeps a disposable style-guide fixture pinned to its mutated terminology source.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $stylePath = 'globalization/terminology/pt-BR.style-guide.json'
    $style = Read-FixtureJson -Root $Root -RelativePath $stylePath
    $style.terminologySource.sha256 = Get-FileHashText -Path (Join-Path $Root `
        'globalization/terminology/pt-BR.terms.json')
    Write-FixtureJson -Root $Root -RelativePath $stylePath -Value $style
}

function Get-TrackedApprovalState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Root)

    $terms = Read-FixtureJson -Root $Root -RelativePath 'globalization/terminology/pt-BR.terms.json'
    $style = Read-FixtureJson -Root $Root -RelativePath 'globalization/terminology/pt-BR.style-guide.json'
    $pendingTerms = @($terms.terms | Where-Object { $_.ptBRDecision.status -eq 'pending' }).Count
    $approved = $terms.status -eq 'approved' -and $style.status -eq 'approved' -and
        $terms.approvals.translator.status -eq 'approved' -and
        $terms.approvals.independentReviewer.status -eq 'approved' -and
        $style.approvals.translator.status -eq 'approved' -and
        $style.approvals.independentReviewer.status -eq 'approved' -and
        $pendingTerms -eq 0
    return @{
        Approved = $approved
        PendingTerms = $pendingTerms
        TermCount = @($terms.terms).Count
        RuleCount = @($style.rules).Count
        RulingCount = @($terms.retiredNameRulings).Count
    }
}

# Builds an approved baseline in a disposable tree. The release each record
# names is deliberately older than the fixture's VERSION: an approval is a
# historical stamp, so an earlier release has to keep passing or every
# version bump would demand two fresh signatures.
function New-ApprovedFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates a disposable terminology tree under TestDrive.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ReleaseVersion = '2026.08.28'
    )

    $root = New-TerminologyFixture -Name $Name
    $termRelative = 'globalization/terminology/pt-BR.terms.json'
    $terms = Read-FixtureJson -Root $root -RelativePath $termRelative
    $terms.status = 'approved'
    # The whole decision is replaced, not just its status: a retained term
    # inherits the exact source spelling, so a targetTerm left behind by a
    # recorded translation is a schema violation rather than a fixture.
    foreach ($term in $terms.terms) {
        $term.ptBRDecision = [pscustomobject]@{ status = 'retained' }
    }
    # The digest is computed over the content this fixture just finished
    # writing, by the same module the gate verifies with -- a fixture that
    # hard-coded one would only be testing that two constants match.
    $termDigest = Get-ApprovableContentDigest -Artifact $terms -Kind terminology
    $terms.approvals.translator = [pscustomobject]@{
        status = 'approved'; approvedBy = 'Synthetic Translator'; approvedAt = '2026-09-03'
        evidence = [pscustomobject]@{ releaseVersion = $ReleaseVersion
            approvedContent = [pscustomobject]$termDigest }
    }
    $terms.approvals.independentReviewer = [pscustomobject]@{
        status = 'approved'; approvedBy = 'Synthetic Reviewer'; approvedAt = '2026-09-03'
        evidence = [pscustomobject]@{ releaseVersion = $ReleaseVersion
            approvedContent = [pscustomobject]$termDigest }
    }
    Write-FixtureJson -Root $root -RelativePath $termRelative -Value $terms

    $styleRelative = 'globalization/terminology/pt-BR.style-guide.json'
    $style = Read-FixtureJson -Root $root -RelativePath $styleRelative
    $style.status = 'approved'
    # Pinned before the digest is taken: the pin is part of what the style
    # guide's approver signed for.
    $style.terminologySource.sha256 = Get-FileHashText -Path (Join-Path $root $termRelative)
    $styleDigest = Get-ApprovableContentDigest -Artifact $style -Kind style-guide
    foreach ($role in @('translator', 'independentReviewer')) {
        $record = $terms.approvals.$role.PSObject.Copy()
        $record.evidence = [pscustomobject]@{ releaseVersion = $ReleaseVersion
            approvedContent = [pscustomobject]$styleDigest }
        $style.approvals.$role = $record
    }
    Write-FixtureJson -Root $root -RelativePath $styleRelative -Value $style
    return $root
}

function Invoke-TerminologyGate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$RequireApproved
    )
    $arguments = @('-NoProfile', '-File', $script:Tool, '-Root', $Root, '-Quiet')
    if ($RequireApproved) { $arguments += '-RequireApproved' }
    $output = & $script:PowerShell @arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}
}

Describe 'the pt-BR terminology and style-guide authority' {

    It 'reports the tracked baseline without overstating it' {
        $state = Get-TrackedApprovalState -Root $script:RepoRoot
        $run = Invoke-TerminologyGate -Root $script:RepoRoot
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $expected = if ($state.Approved) { 'approved' } else { 'approval pending' }
        Assert-Match -Pattern ("$($state.TermCount) term\(s\).*$($state.RulingCount) protected " +
            "ruling\(s\).*$($state.RuleCount) style rule\(s\); $expected") `
            -Actual $run.Output 'the summary does not expose the state the artifacts are actually in'
    }

    It 'makes approval a separate release-mode question' {
        $state = Get-TrackedApprovalState -Root $script:RepoRoot
        $run = Invoke-TerminologyGate -Root $script:RepoRoot -RequireApproved
        if ($state.Approved) {
            Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
            Assert-Match -Pattern '; approved\.' -Actual $run.Output `
                'a complete baseline is not reported as approved'
            return
        }
        Assert-Equal -Expected 1 -Actual $run.Code 'pending human review was reported as approved'
        Assert-Match -Pattern 'baseline approval is incomplete' -Actual $run.Output `
            'the incomplete baseline is not named'
        if ($state.PendingTerms -gt 0) {
            Assert-Match -Pattern "term decisions pending=$($state.PendingTerms)" -Actual $run.Output `
                'unmade pt-BR terminology decisions are not named'
        }
    }

    It 'accepts complete synthetic approval without blessing the checked-in state' {
        $root = New-ApprovedFixture -Name 'complete-approval'
        $run = Invoke-TerminologyGate -Root $root -RequireApproved
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        Assert-Match -Pattern '; approved\.' -Actual $run.Output `
            'a complete synthetic approval did not reach the approved state'
    }

    It 'rejects an approval given for a release this tree has not reached' {
        # The whole public record of an approval is the release it names. A
        # version nobody has cut yet is the one way that record can be fiction
        # while still satisfying its own shape.
        $root = New-ApprovedFixture -Name 'unreached-release' -ReleaseVersion '2099.01.01'
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'an approval outran the tree it was recorded in'
        Assert-Match -Pattern 'names release 2099\.01\.01, which this tree has not reached' `
            -Actual $run.Output 'the unreachable release is not identified'
    }

    It 'rejects a release stamp that is no day of any year' {
        $root = New-ApprovedFixture -Name 'impossible-release' -ReleaseVersion '2026.13.01'
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a thirteenth month passed as a release'
        Assert-Match -Pattern "names release '2026\.13\.01', which is not a calendar version" `
            -Actual $run.Output 'the impossible release stamp is not identified'
    }

    It 'fails closed when either required artifact is deleted' -ForEach @(
        @{ Relative = 'globalization/terminology/pt-BR.terms.json'; Label = 'terminology artifact' },
        @{ Relative = 'globalization/terminology/pt-BR.style-guide.json'; Label = 'style-guide artifact' }
    ) {
        $root = New-TerminologyFixture -Name "missing-$($Relative.GetHashCode())"
        Remove-Item -LiteralPath (Join-Path $root $Relative)
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'deleting an authoritative artifact did not fail validation'
        Assert-Match -Pattern "$([regex]::Escape($Label)) is missing" -Actual $run.Output `
            'the deleted authority is not identified'
    }

    It 'returns unavailable only when an evaluation source is absent' {
        $root = New-TerminologyFixture -Name 'missing-source'
        Remove-Item -LiteralPath (Join-Path $root 'docs/definition.md')
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 2 -Actual $run.Code 'a missing source cannot be evaluated as an ordinary finding'
        Assert-Match -Pattern 'definition source is unavailable' -Actual $run.Output `
            'the unavailable source is not identified'
    }

    It 'invalidates terminology when docs/definition.md changes' {
        $root = New-TerminologyFixture -Name 'definition-drift'
        $path = Join-Path $root 'docs/definition.md'
        [IO.File]::AppendAllText($path, "`nDefinition mutation.`n", [Text.UTF8Encoding]::new($false))
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'definition drift left derived terminology green'
        Assert-Match -Pattern 'definition\.md changed' -Actual $run.Output `
            'the stale terminology source is not identified'
    }

    It 'invalidates terminology when a machine-matched hook literal changes' {
        $root = New-TerminologyFixture -Name 'hook-drift'
        $path = Join-Path $root 'tools/githooks/pre-commit'
        $text = [IO.File]::ReadAllText($path).Replace('status server|status service',
            'servidor de status|servico de status')
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'translated hook search keys passed the terminology gate'
        Assert-Match -Pattern 'retired-name block changed' -Actual $run.Output `
            'the changed machine-literal block is not identified'
        Assert-Match -Pattern 'not an exact hook pair' -Actual $run.Output `
            'the protected prose ruling is not checked against the hook'
    }

    It 'rejects translation fields on protected retired-name rulings' {
        $root = New-TerminologyFixture -Name 'translated-ruling'
        $relative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $terms.retiredNameRulings[0] | Add-Member -NotePropertyName targetTerm `
            -NotePropertyValue 'servidor de status'
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        Update-FixtureStyleHash -Root $root
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a translated machine search key passed validation'
        Assert-Match -Pattern 'does not satisfy terminology\.schema\.json' -Actual $run.Output `
            'the protected ruling schema did not reject a translation field'
    }

    It 'requires every baseline concept and its definition reference' {
        $root = New-TerminologyFixture -Name 'missing-term'
        $relative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $terms.terms = @($terms.terms | Where-Object sourceTerm -NE 'drain')
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        Update-FixtureStyleHash -Root $root
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'deleting a named baseline concept left the source complete'
        Assert-Match -Pattern 'required baseline term is missing: drain' -Actual $run.Output `
            'the deleted baseline concept is not named'
    }

    It 'holds retired-name prose rulings in one stable order' {
        $root = New-TerminologyFixture -Name 'ruling-order'
        $relative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $first = $terms.retiredNameRulings[0]
        $terms.retiredNameRulings[0] = $terms.retiredNameRulings[1]
        $terms.retiredNameRulings[1] = $first
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        Update-FixtureStyleHash -Root $root
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'reordering protected rulings passed as deterministic'
        Assert-Match -Pattern 'ruling 1 changed or moved' -Actual $run.Output `
            'the unstable ruling order is not identified'
    }

    It 'rejects reviewer metadata on a pending approval' {
        $root = New-TerminologyFixture -Name 'pending-with-name'
        $relative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $terms.approvals.translator = [pscustomobject]@{ status = 'pending' }
        $terms.approvals.translator | Add-Member -NotePropertyName approvedBy -NotePropertyValue 'Translator'
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        Update-FixtureStyleHash -Root $root
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a pending record carried false reviewer metadata'
        Assert-Match -Pattern 'does not satisfy terminology\.schema\.json' -Actual $run.Output `
            'the inconsistent approval metadata is not rejected by schema'
    }

    It 'rejects an approved status with no name, date, or named release' {
        $root = New-TerminologyFixture -Name 'unsupported-approval'
        $relative = 'globalization/terminology/pt-BR.style-guide.json'
        $style = Read-FixtureJson -Root $root -RelativePath $relative
        # Approved and bare: the record claims a decision while naming nobody,
        # no date, and no release.
        $style.approvals.translator = [pscustomobject]@{ status = 'approved' }
        Write-FixtureJson -Root $root -RelativePath $relative -Value $style
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'an unsupported approval status passed validation'
        Assert-Match -Pattern 'does not satisfy style-guide\.schema\.json' -Actual $run.Output `
            'the absent approval evidence is not rejected by schema'
    }

    It 'keeps every mapped document draft until the baseline is approved' {
        $root = New-TerminologyFixture -Name 'early-document-review'
        # The rule is about an unapproved baseline, so the fixture puts one there
        # rather than assuming the tracked artifacts still hold one.
        $termRelative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $termRelative
        $terms.status = 'draft'
        $terms.approvals.translator = [pscustomobject]@{ status = 'pending' }
        $terms.approvals.independentReviewer = [pscustomobject]@{ status = 'pending' }
        Write-FixtureJson -Root $root -RelativePath $termRelative -Value $terms
        $styleRelative = 'globalization/terminology/pt-BR.style-guide.json'
        $style = Read-FixtureJson -Root $root -RelativePath $styleRelative
        $style.status = 'draft'
        $style.approvals.translator = [pscustomobject]@{ status = 'pending' }
        $style.approvals.independentReviewer = [pscustomobject]@{ status = 'pending' }
        Write-FixtureJson -Root $root -RelativePath $styleRelative -Value $style
        Update-FixtureStyleHash -Root $root

        $relative = 'globalization/manifests/doc-translations.json'
        $manifest = Read-FixtureJson -Root $root -RelativePath $relative
        $manifest.documents[0].status = 'reviewed'
        Write-FixtureJson -Root $root -RelativePath $relative -Value $manifest
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a document was promoted before glossary approval'
        Assert-Match -Pattern "is 'reviewed' before terminology/style-guide approval" -Actual $run.Output `
            'the prematurely promoted document is not identified'
    }

    It 'requires the style guide to stay pinned to the exact terminology bytes' {
        $root = New-TerminologyFixture -Name 'style-source-drift'
        $relative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $terms.terms[0].meaning = $terms.terms[0].meaning + ' Changed.'
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a stale style-guide terminology hash passed validation'
        Assert-Match -Pattern 'terminology source changed after the style guide was derived' `
            -Actual $run.Output 'the stale style-guide dependency is not identified'
    }

    It 'ties recording a document reviewed to the state of the baseline approval' {
        # The gate above catches the invalid state after it exists. This is the
        # same rule at the only place that writes the status, so the record
        # cannot enter the contradiction in the first place. Which side of the
        # rule this proves depends on the tracked baseline, and both sides are
        # the same rule.
        $state = Get-TrackedApprovalState -Root $script:RepoRoot
        $manifest = Join-Path $TestDrive 'refused-doc-translations.json'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'globalization/manifests/doc-translations.json') `
            -Destination $manifest
        $before = [IO.File]::ReadAllText($manifest)

        $run = Invoke-DocTranslationAccept -Manifest $manifest -Status 'reviewed'
        if ($state.Approved) {
            Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
            $recorded = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifest))
            $entry = @($recorded.documents | Where-Object { $_.repo -eq 'yuruna' -and $_.source -eq 'docs/operator.md' })
            Assert-StringEqual -Expected 'reviewed' -Actual $entry[0].status `
                'an approved baseline still refused the review it exists to permit'
            return
        }
        Assert-Equal -Expected 2 -Actual $run.Code 'a review was recorded against an unapproved glossary'
        Assert-Match -Pattern 'approval is incomplete' -Actual $run.Output `
            'the refusal does not name the missing approval'
        Assert-StringEqual -Expected $before -Actual ([IO.File]::ReadAllText($manifest)) `
            'the refused run still rewrote the record'
    }

    It 'still registers a draft while the baseline approval is pending' {
        # Drafting is the work that proceeds in parallel with approval; refusing
        # it too would stop the lane the refusal above exists to protect.
        $manifest = Join-Path $TestDrive 'accepted-doc-translations.json'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'globalization/manifests/doc-translations.json') `
            -Destination $manifest

        $run = Invoke-DocTranslationAccept -Manifest $manifest -Status 'draft'
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $recorded = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifest))
        $entry = @($recorded.documents | Where-Object { $_.repo -eq 'yuruna' -and $_.source -eq 'docs/operator.md' })
        Assert-Equal -Expected 1 -Actual $entry.Count 'the operator document left the record'
        Assert-StringEqual -Expected 'draft' -Actual $entry[0].status `
            'a draft registration did not record draft status'
    }

    It 'requires the style topics needed by later translation handoffs' {
        $root = New-TerminologyFixture -Name 'missing-style-rule'
        $relative = 'globalization/terminology/pt-BR.style-guide.json'
        $style = Read-FixtureJson -Root $root -RelativePath $relative
        $style.rules = @($style.rules | Where-Object id -NE 'machine-matched-literals')
        Write-FixtureJson -Root $root -RelativePath $relative -Value $style
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'deleting the protected-literal rule left the guide complete'
        Assert-Match -Pattern 'required pt-BR style rule is missing: machine-matched-literals' `
            -Actual $run.Output 'the missing style topic is not identified'
    }
}
