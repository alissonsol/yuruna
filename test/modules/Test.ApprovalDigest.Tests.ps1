<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42d1c8b7-4e05-4a6f-9c31-6b0a7d2e5f48
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization terminology approval digest
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Prove the approval digest binds an approval to the words that were approved,
    and to nothing else.

    Run: Invoke-Pester -Path test/modules/Test.ApprovalDigest.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.ApprovalDigest.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here

function Read-Artifact {
    param([Parameter(Mandatory)][string]$RelativePath)
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $script:RepoRoot $RelativePath)))
}
function Get-TermsDigest { param($Artifact) (Get-ApprovableContentDigest -Artifact $Artifact -Kind terminology).sha256 }
function Get-StyleDigest { param($Artifact) (Get-ApprovableContentDigest -Artifact $Artifact -Kind style-guide).sha256 }
}

Describe 'the digest covers the content an approver read' {
    It 'is stable for the same artifact' {
        $terms = Read-Artifact -RelativePath 'globalization/terminology/pt-BR.terms.json'
        Assert-StringEqual -Expected (Get-TermsDigest -Artifact $terms) -Actual (Get-TermsDigest -Artifact $terms) `
            -Because 'a digest that moved on its own could never be compared to a recorded one'
    }

    It 'is 64 hex characters under a named algorithm' {
        $digest = Get-ApprovableContentDigest -Artifact (Read-Artifact -RelativePath 'globalization/terminology/pt-BR.terms.json') `
            -Kind terminology
        Assert-StringEqual -Expected (Get-ApprovalDigestAlgorithm) -Actual ([string]$digest.algorithm)
        Assert-Match '^[0-9a-f]{64}$' ([string]$digest.sha256) 'the digest must be a plain lowercase SHA-256'
    }

    It 'changes when a term decision changes' {
        $terms = Read-Artifact -RelativePath 'globalization/terminology/pt-BR.terms.json'
        $before = Get-TermsDigest -Artifact $terms
        $terms.terms[0].ptBRDecision | Add-Member -NotePropertyName targetTerm -NotePropertyValue 'outro' -Force
        Assert-NotEqual -Expected $before -Actual (Get-TermsDigest -Artifact $terms) `
            -Because 'changing what a term translates to is exactly what an approval is about'
    }

    It 'changes when a style rule is appended' {
        # The mutation that passes without a digest: a rule nobody read, added
        # after both signatures, leaving the record still saying approved.
        $style = Read-Artifact -RelativePath 'globalization/terminology/pt-BR.style-guide.json'
        $before = Get-StyleDigest -Artifact $style
        $style.rules += [pscustomobject]@{ id = 'unapproved'; topic = 'Unapproved'
            guidance = 'Text no approver ever saw.' }
        Assert-NotEqual -Expected $before -Actual (Get-StyleDigest -Artifact $style) `
            -Because 'an appended rule is content nobody approved'
    }

    It 'changes when an approved rule is reversed in place' {
        $style = Read-Artifact -RelativePath 'globalization/terminology/pt-BR.style-guide.json'
        $before = Get-StyleDigest -Artifact $style
        $style.rules[0].guidance = 'The opposite of whatever this said.'
        Assert-NotEqual -Expected $before -Actual (Get-StyleDigest -Artifact $style) `
            -Because 'inverting guidance keeps the rule count and changes the meaning'
    }

    It 'changes when the style guide is repinned over different terminology' {
        $style = Read-Artifact -RelativePath 'globalization/terminology/pt-BR.style-guide.json'
        $before = Get-StyleDigest -Artifact $style
        $style.terminologySource.sha256 = ('a' * 64)
        Assert-NotEqual -Expected $before -Actual (Get-StyleDigest -Artifact $style) `
            -Because 'the guide is written against particular terminology, so the pin is part of it'
    }

    It 'changes when rules are reordered' {
        # Authored order is content: the rules are read in the order written.
        $style = Read-Artifact -RelativePath 'globalization/terminology/pt-BR.style-guide.json'
        $before = Get-StyleDigest -Artifact $style
        $reversed = @($style.rules)[($style.rules.Count - 1)..0]
        $style.rules = $reversed
        Assert-NotEqual -Expected $before -Actual (Get-StyleDigest -Artifact $style) `
            -Because 'a reordered guide reads differently even with the same rules in it'
    }
}

Describe 'the digest deliberately ignores what is not content' {
    It 'ignores the approval records it will be stored inside' {
        # Self-reference would make it uncomputable: the digest goes into the
        # approval, so it cannot also cover the approval.
        $terms = Read-Artifact -RelativePath 'globalization/terminology/pt-BR.terms.json'
        $before = Get-TermsDigest -Artifact $terms
        $terms.approvals.translator = [pscustomobject]@{ status = 'approved'
            approvedBy = 'Someone'; approvedAt = '2026-09-09'
            evidence = [pscustomobject]@{ releaseVersion = '2026.09.24' } }
        $terms.status = 'approved'
        Assert-StringEqual -Expected $before -Actual (Get-TermsDigest -Artifact $terms) `
            -Because 'recording the approval must not change what the approval covers'
    }

    It 'ignores a release-version-only bump' {
        # The plan's other half: an unchanged artifact under a new VERSION keeps
        # its approval, so a routine bump does not send two people back to sign.
        $style = Read-Artifact -RelativePath 'globalization/terminology/pt-BR.style-guide.json'
        $before = Get-StyleDigest -Artifact $style
        foreach ($role in @('translator', 'independentReviewer')) {
            $style.approvals.$role = [pscustomobject]@{ status = 'approved'
                approvedBy = "Person $role"; approvedAt = '2026-09-09'
                evidence = [pscustomobject]@{ releaseVersion = '2099.12.31' } }
        }
        Assert-StringEqual -Expected $before -Actual (Get-StyleDigest -Artifact $style) `
            -Because 'the release stamp is not part of the words that were approved'
    }
}

Describe 'the canonical form does not depend on the host' {
    It 'sorts member names the same way in any culture' {
        # Ordinal, not culture-aware. A Turkish or Swedish collation orders
        # these differently, which would change the digest on that host without
        # changing a word of the content -- and the value is compared across
        # hosts byte for byte.
        # Distinct names, chosen so ordinal and culture-aware ordering disagree:
        # ordinal puts every capital before every lowercase letter, Turkish
        # treats dotted and dotless i as separate letters, and Swedish sorts a
        # ring-a after z.
        $value = [pscustomobject]@{ zebra = 1; Apple = 2; india = 3; Irish = 4; angstrom = 5 }
        $prior = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            $baseline = ConvertTo-CanonicalApprovalJson -Value $value
            foreach ($culture in @('tr-TR', 'sv-SE', 'en-US')) {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new($culture)
                Assert-StringEqual -Expected $baseline -Actual (ConvertTo-CanonicalApprovalJson -Value $value) `
                    -Because "the canonical form changed under $culture"
            }
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $prior
        }
    }

    It 'writes numbers in the invariant culture' {
        # A comma decimal separator would be a different document.
        $prior = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('pt-BR')
            Assert-Match '1\.5' (ConvertTo-CanonicalApprovalJson -Value ([pscustomobject]@{ n = 1.5 })) `
                'a locale decimal separator would change the digest without changing the content'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $prior
        }
    }
}
