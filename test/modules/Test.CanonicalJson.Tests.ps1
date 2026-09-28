<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42d1c8b7-4e05-4a6f-9c31-6b0a7d2e5f48
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization canonical json digest
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
    Prove the canonical JSON text is one text per value: independent of member
    order, collection type and host culture, and different for any change of
    content.

    Run: Invoke-Pester -Path test/modules/Test.CanonicalJson.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.CanonicalJson.psm1') -Force -Global -DisableNameChecking
}

Describe 'the canonical form is one text per value' {
    It 'sorts keys ordinally for a hashtable and a PSCustomObject alike' {
        $expected = '{"Apple":2,"zebra":1}'
        Assert-StringEqual -Expected $expected -Actual (ConvertTo-CanonicalApprovalJson -Value @{ zebra = 1; Apple = 2 })
        Assert-StringEqual -Expected $expected -Actual (ConvertTo-CanonicalApprovalJson -Value ([pscustomobject]@{ zebra = 1; Apple = 2 }))
    }

    It 'keeps array order' {
        # Two lists holding the same items in a different order are different
        # values; sorting them would give both the same digest.
        Assert-StringEqual -Expected '["b","a"]' -Actual (ConvertTo-CanonicalApprovalJson -Value @('b', 'a'))
        Assert-StringEqual -Expected '{"rows":["b","a"]}' -Actual (ConvertTo-CanonicalApprovalJson -Value @{ rows = @('b', 'a') })
    }

    It 'renders null, true and false as JSON literals' {
        Assert-StringEqual -Expected '{"a":null,"b":true,"c":false}' `
            -Actual (ConvertTo-CanonicalApprovalJson -Value ([ordered]@{ a = $null; b = $true; c = $false }))
    }

    It 'escapes strings the way ConvertTo-Json -Compress does' {
        $text = 'quote " backslash \ tab ' + "`t" + ' line ' + "`n" + ' accent ' + [char]0x00E9
        Assert-StringEqual -Expected (ConvertTo-Json -InputObject $text -Compress) -Actual (ConvertTo-CanonicalApprovalJson -Value $text)
    }

    It 'is stable for the same input' {
        $value = [pscustomobject]@{ locale = 'xx-XX'; rows = @([pscustomobject]@{ id = 'a'; text = 'one' }) }
        Assert-StringEqual -Expected (ConvertTo-CanonicalApprovalJson -Value $value) -Actual (ConvertTo-CanonicalApprovalJson -Value $value)
    }

    It 'changes when a nested value changes' {
        $value = [pscustomobject]@{ rows = @([pscustomobject]@{ id = 'a'; text = 'one' }) }
        $before = ConvertTo-CanonicalApprovalJson -Value $value
        $value.rows[0].text = 'two'
        Assert-NotEqual -Expected $before -Actual (ConvertTo-CanonicalApprovalJson -Value $value) `
            -Because 'a digest that ignored a nested edit could not tell two requests apart'
    }

    It 'treats an ordered and an unordered dictionary with the same members the same' {
        $ordered = [ordered]@{ b = 2; a = 1 }
        $unordered = @{ a = 1; b = 2 }
        Assert-StringEqual -Expected (ConvertTo-CanonicalApprovalJson -Value $unordered) -Actual (ConvertTo-CanonicalApprovalJson -Value $ordered)
    }

    It 'writes a decimal without a culture group separator' {
        $prior = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('de-DE')
            Assert-StringEqual -Expected '{"n":1234567.5}' -Actual (ConvertTo-CanonicalApprovalJson -Value @{ n = [decimal]1234567.5 })
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $prior
        }
    }

    It 'sorts a Turkish dotless i ordinally' {
        # Ordinal places I (U+0049) before i (U+0069) before the dotless i
        # (U+0131); a Turkish collation groups the two lowercase letters apart.
        # A PowerShell hash literal folds case, so the three keys need an
        # ordinal dictionary to coexist.
        $dotless = [string][char]0x0131
        $value = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        $value[$dotless] = 3
        $value['i'] = 2
        $value['I'] = 1
        $prior = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('tr-TR')
            $text = ConvertTo-CanonicalApprovalJson -Value $value
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $prior
        }
        Assert-StringEqual -Expected ('{"I":1,"i":2,' + (ConvertTo-Json -InputObject $dotless -Compress) + ':3}') -Actual $text
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
