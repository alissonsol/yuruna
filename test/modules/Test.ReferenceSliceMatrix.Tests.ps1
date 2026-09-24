<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42e79a16-80d2-4aa2-9fd8-20b3b66b79ee
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization accessibility pseudo rtl reflow focus pester
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
    Run the shipped status and pool reference slices as one pseudo-locale UI
    matrix at the narrow/zoom-equivalent viewport and a desktop viewport.
.DESCRIPTION
    The ordinary accessibility sweep and the pseudo rendering suites used to
    be separate proofs: English pages had layout/focus evidence, while
    pseudo pages proved only their text. These fixtures come from the shipped
    builders and load the shipped generated assets, so each expanded and RTL
    state is measured for direction, visible catalog output, focus, contrast,
    and reflow at 320 and 1280 CSS pixels in both palettes.

    Run: Invoke-Pester -Path test/modules/Test.ReferenceSliceMatrix.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Exporter = Join-Path $script:RepoRoot 'tools/Export-GeneratedPages.ps1'
$script:A11y = Join-Path $script:RepoRoot 'tools/Invoke-A11yCheck.ps1'
$script:Output = Join-Path $TestDrive 'generated'
$null = & $script:Exporter -OutputDirectory $script:Output -Quiet

function Invoke-ReferenceA11y {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Serve,
        [Parameter(Mandatory)][string]$Filter,
        [int[]]$Width = @(320, 1280),
        [string[]]$Scheme = @('light', 'dark'),
        [switch]$CheckFocusTargets,
        [switch]$Detailed
    )

    $quotedTool = $script:A11y.Replace("'", "''")
    $quotedServe = $Serve.Replace("'", "''")
    $quotedFilter = $Filter.Replace("'", "''")
    $widthLiteral = @($Width | ForEach-Object { [string]$_ }) -join ','
    $schemeLiteral = @($Scheme | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ','
    $focusTargets = if ($CheckFocusTargets) { ' -CheckFocusTargets' } else { '' }
    $quiet = if ($Detailed) { '' } else { ' -Quiet' }
    $command = "& '$quotedTool' -Serve '$quotedServe' -PageFilter '$quotedFilter' " +
        "-Width @($widthLiteral) -Scheme @($schemeLiteral) -RequireDirection$focusTargets$quiet"
    $text = & pwsh -NoProfile -Command $command 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $text }
}
}

Describe 'the two shipped globalization slices form one UI matrix' {

    It 'materializes both pseudo locales from each shipped builder' {
        $findings = @()
        foreach ($slice in 'status', 'pool') {
            foreach ($locale in @(
                    @{ Tag = 'qps-Ploc'; Direction = 'ltr' }
                    @{ Tag = 'qps-Plocm'; Direction = 'rtl' })) {
                $name = "$slice-reference-$($locale.Tag).html"
                $path = Join-Path $script:Output $name
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $findings += "$name was not exported"
                    continue
                }
                $html = [IO.File]::ReadAllText($path)
                if (-not $html.Contains("<html lang=`"$($locale.Tag)`" dir=`"$($locale.Direction)`"")) {
                    $findings += "$name has no server-owned language/direction context"
                }
                if (-not $html.Contains("$($locale.Tag).$slice.js")) {
                    $findings += "$name does not load its shipped generated catalog"
                }
                if (-not $html.Contains('data-yuruna-globalization-reference')) {
                    $findings += "$name has no visible reference-state assertion"
                }
            }
        }
        Assert-NoFinding $findings 'the composed reference matrix is incomplete'
    }

    It 'passes pseudo text, RTL, focus-target, contrast, and 320px reflow checks together' {
        $result = Invoke-ReferenceA11y -Serve $script:Output `
            -Filter '*-reference-qps-*.html' -CheckFocusTargets
        if ($result.Code -eq 2) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium is available for the composed matrix'
            return
        }
        Assert-Equal -Expected 0 -Actual $result.Code `
            "the composed status/pool matrix failed:`n$($result.Output)"
        Assert-Match '16 page-view\(s\) measured across 4 page\(s\), 0 finding\(s\)' $result.Output `
            'the matrix did not measure every slice/locale/width/palette row'
    }

    It 'fails when the server-owned direction is wrong or the pseudo catalog disappears' {
        $directionRoot = Join-Path $TestDrive 'bad-direction'
        $catalogRoot = Join-Path $TestDrive 'bad-catalog'
        Copy-Item -LiteralPath $script:Output -Destination $directionRoot -Recurse
        Copy-Item -LiteralPath $script:Output -Destination $catalogRoot -Recurse

        $name = 'status-reference-qps-Plocm.html'
        $directionPath = Join-Path $directionRoot $name
        $directionHtml = [IO.File]::ReadAllText($directionPath).Replace(' dir="rtl"', ' dir="ltr"')
        [IO.File]::WriteAllText($directionPath, $directionHtml)
        $direction = Invoke-ReferenceA11y -Serve $directionRoot -Filter $name -Width 320 -Scheme light -Detailed

        $catalogPath = Join-Path $catalogRoot $name
        $catalogHtml = [IO.File]::ReadAllText($catalogPath)
        $catalogHtml = $catalogHtml.Replace('<script src="qps-Plocm.status.js"></script>', '')
        [IO.File]::WriteAllText($catalogPath, $catalogHtml)
        $catalog = Invoke-ReferenceA11y -Serve $catalogRoot -Filter $name -Width 320 -Scheme light -Detailed

        if ($direction.Code -eq 2 -or $catalog.Code -eq 2) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium is available for the composed mutations'
            return
        }
        Assert-Equal -Expected 1 -Actual $direction.Code 'an incorrect root direction passed the composed matrix'
        Assert-Match 'direction' $direction.Output 'the direction mutation produced no useful finding'
        Assert-Equal -Expected 1 -Actual $catalog.Code 'a missing pseudo catalog passed the composed matrix'
        Assert-Match 'locale-render' $catalog.Output 'the stale catalog mutation produced no useful finding'
    }
}
