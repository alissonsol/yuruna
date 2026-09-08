<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42696ce9-89fb-43d5-ab5b-3d4eda2725cd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test system diagnostic bios computerinfo pester
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
    Guards the stable, complete BIOS section in Get-SystemDiagnostic.ps1.
.DESCRIPTION
    BIOS captures are compared across machines and over time, so the output
    must not inherit Get-ComputerInfo's property order, the current culture,
    or PowerShell's display-width-dependent formatting. These tests lift the
    three pure BIOS helpers from the diagnostic script and exercise them with
    an intentionally shuffled Get-ComputerInfo-shaped object.

    The fixture covers absent and null fields, an empty enumerable, complete
    arrays in provider order, strings requiring JSON escaping, booleans,
    numbers, enums, DateTime and DateTimeOffset values, and future Bios*
    fields. Structural assertions keep the section in one fixed location and
    pin the platform/unavailable markers without executing the full diagnostic
    or reading the machine running this suite.

    Throw-based assertions use Test.Assert.psm1. Run:
      Invoke-Pester -Path test/modules/Test.SystemDiagnosticBios.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:DiagPath = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'
    $script:DiagAst  = Get-YurunaTestFileAst -Path $script:DiagPath
    $script:DiagText = Get-Content -Raw -LiteralPath $script:DiagPath

    # Get-SystemDiagnostic is a top-to-bottom executable script, so dot-sourcing
    # it would run every host/network/container probe. Lift only the pure helper
    # bodies from the shipped AST, in dependency order.
    foreach ($name in 'Get-BiosPropertyOrder', 'Format-BiosDiagnosticValue', 'Get-BiosDiagnosticLine') {
        $definition = Get-YurunaTestFunctionAst -Path $script:DiagPath -Name $name
        if (-not $definition) {
            throw "Test.SystemDiagnosticBios.Tests.ps1: helper '$name' was not found in $($script:DiagPath)."
        }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $script:CanonicalBiosOrder = @(
        'BiosCharacteristics'
        'BiosBIOSVersion'
        'BiosBuildNumber'
        'BiosCaption'
        'BiosCodeSet'
        'BiosCurrentLanguage'
        'BiosDescription'
        'BiosEmbeddedControllerMajorVersion'
        'BiosEmbeddedControllerMinorVersion'
        'BiosFirmwareType'
        'BiosIdentificationCode'
        'BiosInstallableLanguages'
        'BiosInstallDate'
        'BiosLanguageEdition'
        'BiosListOfLanguages'
        'BiosManufacturer'
        'BiosName'
        'BiosOtherTargetOS'
        'BiosPrimaryBIOS'
        'BiosReleaseDate'
        'BiosSerialNumber'
        'BiosSMBIOSBIOSVersion'
        'BiosSMBIOSMajorVersion'
        'BiosSMBIOSMinorVersion'
        'BiosSMBIOSPresent'
        'BiosSoftwareElementState'
        'BiosStatus'
        'BiosSystemBiosMajorVersion'
        'BiosSystemBiosMinorVersion'
        'BiosTargetOperatingSystem'
        'BiosVersion'
    )

    function Get-ShuffledBiosFixture {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([switch]$Reverse)

        $values = [ordered]@{
            CsName                  = 'must not enter the BIOS section'
            BiosFutureZulu          = 'future-zulu'
            BiosSMBIOSPresent       = $true
            BiosCharacteristics     = [uint16[]]@(11, 7, 3)
            BiosReleaseDate         = [datetimeoffset]::new(2024, 2, 3, 4, 5, 6, 789,
                                                [timespan]::FromHours(5.5))
            BiosBuildNumber         = [decimal]1234.5
            BiosListOfLanguages     = [System.Collections.Generic.List[string]]::new()
            BiosBIOSVersion         = [string[]]@('provider-second', 'provider-first')
            BiosCaption             = $null
            BiosManufacturer        = "ACME `"Firmware`"`nLab"
            BiosFirmwareType        = [System.DayOfWeek]::Friday
            BiosInstallDate         = [datetime]::SpecifyKind(
                                          [datetime]::new(2025, 6, 7, 8, 9, 10, 321),
                                          [System.DateTimeKind]::Utc)
            BiosFutureAlpha         = 'future-alpha'
        }
        $names = [string[]]@($values.Keys)
        if ($Reverse) { [array]::Reverse($names) }

        $fixture = [pscustomobject]@{}
        foreach ($name in $names) {
            $fixture | Add-Member -MemberType NoteProperty -Name $name -Value $values[$name]
        }
        return $fixture
    }

    function Get-BiosLineFieldName {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Line)

        if ($Line -notmatch '^\s*(Bios[A-Za-z0-9]+)\s*:') {
            throw "Not a standardized BIOS field line: [$Line]"
        }
        return $Matches[1]
    }

    function Get-BiosFieldLine {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string[]]$Line,
            [Parameter(Mandatory)][string]$Name
        )

        $match = @($Line | Where-Object { $_ -match ("^\s*" + [regex]::Escape($Name) + '\s*:') })
        if ($match.Count -ne 1) {
            throw "Expected exactly one '$Name' line, found $($match.Count)."
        }
        return $match[0]
    }

    function Get-DiagnosticSectionCall {
        [CmdletBinding()]
        [OutputType([System.Array])]
        param([Parameter(Mandatory)][string]$Title)

        $wantedTitle = $Title
        @($script:DiagAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Invoke-DiagnosticSection' -and
                    $node.CommandElements.Count -ge 2 -and
                    $node.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.CommandElements[1].Value -eq $wantedTitle
                }.GetNewClosure(), $true))
    }

    $script:BiosFixture        = Get-ShuffledBiosFixture
    $script:ReverseBiosFixture = Get-ShuffledBiosFixture -Reverse
}

Describe 'Get-SystemDiagnostic BIOS canonical field contract' {
    It 'keeps the complete 31-field Get-ComputerInfo source order' {
        $actual = @(Get-BiosPropertyOrder)
        Assert-Equal -Expected 31 -Actual $actual.Count
        Assert-StringEqual -Expected ($script:CanonicalBiosOrder -join "`n") `
            -Actual ($actual -join "`n") `
            -Because 'a field insertion or reorder makes otherwise comparable machine reports churn'
    }

    It 'emits every canonical field once, including absent and null values' {
        $lines = @(Get-BiosDiagnosticLine -ComputerInfo $script:BiosFixture)
        $names = @($lines | ForEach-Object { Get-BiosLineFieldName -Line $_ })

        Assert-Equal -Expected 33 -Actual $lines.Count `
            -Because '31 canonical rows plus the two future Bios* fixture fields must be retained'
        foreach ($name in $script:CanonicalBiosOrder) {
            Assert-Equal -Expected 1 -Actual @($names | Where-Object { $_ -ceq $name }).Count `
                -Because "$name must occupy exactly one comparison row"
        }
        Assert-Match '^\s*BiosCaption\s*:\s*\(not reported\)$' `
            (Get-BiosFieldLine -Line $lines -Name 'BiosCaption')
        Assert-Match '^\s*BiosCodeSet\s*:\s*\(not reported\)$' `
            (Get-BiosFieldLine -Line $lines -Name 'BiosCodeSet')
    }

    It 'appends only future Bios fields in ordinal order after the canonical rows' {
        $lines = @(Get-BiosDiagnosticLine -ComputerInfo $script:BiosFixture)
        $names = @($lines | ForEach-Object { Get-BiosLineFieldName -Line $_ })
        $expected = @($script:CanonicalBiosOrder) + @('BiosFutureAlpha', 'BiosFutureZulu')

        Assert-StringEqual -Expected ($expected -join "`n") -Actual ($names -join "`n")
        Assert-True (-not ($lines -match 'CsName')) `
            'Get-ComputerInfo fields outside Bios* must not pollute the standardized section'
    }

    It 'is byte-stable when the provider returns the same fields in reverse order' {
        $first  = @(Get-BiosDiagnosticLine -ComputerInfo $script:BiosFixture) -join "`n"
        $second = @(Get-BiosDiagnosticLine -ComputerInfo $script:ReverseBiosFixture) -join "`n"
        Assert-StringEqual -Expected $first -Actual $second
    }
}

Describe 'Format-BiosDiagnosticValue normalization' {
    It 'distinguishes an unavailable value from an empty string and empty enumerable' {
        Assert-StringEqual -Expected '(not reported)' -Actual (Format-BiosDiagnosticValue -Value $null)
        Assert-StringEqual -Expected '""'             -Actual (Format-BiosDiagnosticValue -Value '')

        $empty = [System.Collections.Generic.List[string]]::new()
        Assert-StringEqual -Expected '[]' -Actual (Format-BiosDiagnosticValue -Value $empty)
    }

    It 'JSON-quotes strings and keeps control characters on one escaped line' {
        $value  = "ACME `"Firmware`"`nLab`tUEFI"
        $actual = Format-BiosDiagnosticValue -Value $value
        Assert-StringEqual -Expected '"ACME \"Firmware\"\nLab\tUEFI"' -Actual $actual
        Assert-Equal -Expected 1 -Actual @($actual).Count
        Assert-True (-not $actual.Contains("`n")) 'an embedded newline must not split a comparison row'
    }

    It 'renders booleans lowercase and numeric scalars with invariant culture' {
        $oldCulture   = [System.Threading.Thread]::CurrentThread.CurrentCulture
        $oldUiCulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture   = [cultureinfo]::GetCultureInfo('pt-BR')
            [System.Threading.Thread]::CurrentThread.CurrentUICulture = [cultureinfo]::GetCultureInfo('pt-BR')
            Assert-StringEqual -Expected 'true'   -Actual (Format-BiosDiagnosticValue -Value $true)
            Assert-StringEqual -Expected 'false'  -Actual (Format-BiosDiagnosticValue -Value $false)
            Assert-StringEqual -Expected '1234.5' -Actual (Format-BiosDiagnosticValue -Value ([decimal]1234.5))
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture   = $oldCulture
            [System.Threading.Thread]::CurrentThread.CurrentUICulture = $oldUiCulture
        }
    }

    It 'normalizes DateTime and DateTimeOffset values to UTC with seven fractional digits' {
        $utc = [datetime]::SpecifyKind([datetime]::new(2025, 6, 7, 8, 9, 10, 321),
                                       [System.DateTimeKind]::Utc)
        $offset = [datetimeoffset]::new(2024, 2, 3, 4, 5, 6, 789,
                                        [timespan]::FromHours(5.5))

        Assert-StringEqual -Expected '2025-06-07T08:09:10.3210000Z' `
            -Actual (Format-BiosDiagnosticValue -Value $utc)
        Assert-StringEqual -Expected '2024-02-02T22:35:06.7890000Z' `
            -Actual (Format-BiosDiagnosticValue -Value $offset)
    }

    It 'keeps arrays complete, on one line, and in provider order' {
        $actual = Format-BiosDiagnosticValue -Value ([object[]]@('provider-second', 'provider-first', $null, $true))
        Assert-StringEqual -Expected '["provider-second", "provider-first", (not reported), true]' -Actual $actual
        Assert-Equal -Expected 1 -Actual @($actual).Count `
            -Because 'PowerShell pipeline enumeration must not split one BIOS property across rows'

        Assert-StringEqual -Expected '[11, 7, 3]' `
            -Actual (Format-BiosDiagnosticValue -Value ([uint16[]]@(11, 7, 3)))
    }

    It 'renders enum-backed BIOS values with both their numeric and symbolic forms' {
        Assert-StringEqual -Expected '5 (Friday)' `
            -Actual (Format-BiosDiagnosticValue -Value ([System.DayOfWeek]::Friday))
    }

    It 'produces the same complete section under different process cultures' {
        $oldCulture   = [System.Threading.Thread]::CurrentThread.CurrentCulture
        $oldUiCulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture   = [cultureinfo]::GetCultureInfo('en-US')
            [System.Threading.Thread]::CurrentThread.CurrentUICulture = [cultureinfo]::GetCultureInfo('en-US')
            $english = @(Get-BiosDiagnosticLine -ComputerInfo $script:BiosFixture) -join "`n"

            [System.Threading.Thread]::CurrentThread.CurrentCulture   = [cultureinfo]::GetCultureInfo('pt-BR')
            [System.Threading.Thread]::CurrentThread.CurrentUICulture = [cultureinfo]::GetCultureInfo('pt-BR')
            $portuguese = @(Get-BiosDiagnosticLine -ComputerInfo $script:BiosFixture) -join "`n"
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture   = $oldCulture
            [System.Threading.Thread]::CurrentThread.CurrentUICulture = $oldUiCulture
        }
        Assert-StringEqual -Expected $english -Actual $portuguese
    }
}

Describe 'Get-SystemDiagnostic BIOS section wiring' {
    It 'appears exactly once between HOST and CPU' {
        $hostSection = @(Get-DiagnosticSectionCall -Title 'HOST')
        $biosSection = @(Get-DiagnosticSectionCall -Title 'BIOS')
        $cpuSection  = @(Get-DiagnosticSectionCall -Title 'CPU')

        Assert-Equal -Expected 1 -Actual $hostSection.Count
        Assert-Equal -Expected 1 -Actual $biosSection.Count
        Assert-Equal -Expected 1 -Actual $cpuSection.Count
        Assert-True ($hostSection[0].Extent.StartOffset -lt $biosSection[0].Extent.StartOffset) `
            'BIOS must remain after the host identity/software section'
        Assert-True ($biosSection[0].Extent.StartOffset -lt $cpuSection[0].Extent.StartOffset) `
            'BIOS must remain before CPU so every report has the same section sequence'
    }

    It 'performs one complete Get-ComputerInfo BIOS query and avoids display formatting' {
        $bios = @(Get-DiagnosticSectionCall -Title 'BIOS')[0]
        $queries = @($bios.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-ComputerInfo'
                }, $true))
        Assert-Equal -Expected 1 -Actual $queries.Count
        Assert-Match 'Get-ComputerInfo\s+-Property\s+''Bios\*''\s+-ErrorAction\s+Stop' `
            $queries[0].Extent.Text
        Assert-True ($bios.Extent.Text -notmatch '(?i)\bFormat-List\b') `
            'Format-List can reorder fields, truncate arrays, and wrap to the current display width'
    }

    It 'pins the Windows-only, missing-command, no-data, and failed-query markers' {
        $biosText = @(Get-DiagnosticSectionCall -Title 'BIOS')[0].Extent.Text
        foreach ($literal in @(
                '(BIOS information is available through Get-ComputerInfo on Windows only.)'
                '(BIOS information unavailable: Get-ComputerInfo is not installed.)'
                '(BIOS information unavailable: Get-ComputerInfo returned no data.)'
                '(BIOS information unavailable: Get-ComputerInfo failed: {0})'
            )) {
            Assert-True ($biosText.Contains($literal)) "BIOS section lost stable marker: $literal"
        }
        Assert-Match 'if\s*\(\s*-not\s+\$IsWindows\s*\)' $biosText
        Assert-Match '(?s)try\s*\{.*Get-ComputerInfo.*\}\s*catch\s*\{' $biosText
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
