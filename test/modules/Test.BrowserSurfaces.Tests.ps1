<#PSScriptInfo
.VERSION 2026.09.24
.GUID 424625c3-3298-4700-bc3c-2c6431031514
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test browser surfaces globalization pester
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
    Holds the browser surfaces this repository ships to the invariants that
    no single service can check on its own.
.DESCRIPTION
    Three things live here because nothing else is positioned to see them.

    The shared page-chrome block is copied into each service UI because
    go:embed cannot cross a module boundary, so the copies are held together
    by byte identity -- which first requires the design tokens they are
    written from to carry the same values in every UI.

    The provisioned Squid page is localized at deployment time by
    ConvertTo-ProvisionedCatalogHtml against the shipped cloud-init seed,
    which is the only place that rendering path is exercised end to end.

    The registered globalization acceptance cases run the Node and Go
    product checks over the generated pages, the expanded and mirrored
    locales, and the capability-off, keyboard, IME and hostile-bidi paths.

    Run: Invoke-Pester -Path test/modules/Test.BrowserSurfaces.Tests.ps1
#>

BeforeAll {
Import-Module (Join-Path $PSScriptRoot 'Test.ProductGlobalization.psm1') -Force -Global -DisableNameChecking
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
}

Describe 'the shared chrome palette agrees across the UIs that copy it' {

    It 'gives every chrome token the same value in every UI that carries it' {
        # The page-chrome block is copied per UI because go:embed cannot cross
        # a module boundary, and a byte-identity test holds the copies
        # together.
        $sheets = @{
            'status'       = 'test/status/yuruna.common.css'
            'pool-control' = 'test/extension/pool-control-service/server/internal/httpsrv/web/assets/style.css'
            'stash'        = 'test/extension/stash-service/server/internal/httpsrv/web/assets/style.css'
            'download'     = 'test/extension/download-agent-service/server/internal/httpsrv/web/assets/style.css'
        }
        $seen = @{}
        foreach ($name in $sheets.Keys) {
            $full = [IO.Path]::Combine($script:RepoRoot, ($sheets[$name] -replace '/', [IO.Path]::DirectorySeparatorChar))
            $text = Get-Content -Raw -LiteralPath $full
            # The base :root block is the comparison set, deliberately. The
            # dark-scheme override restates a subset of the same token names,
            # so folding both into one name-keyed map would end up comparing
            # one UI's light value against another UI's dark one.
            $cut = $text.IndexOf('prefers-color-scheme')
            if ($cut -gt 0) { $text = $text.Substring(0, $cut) }
            foreach ($m in [regex]::Matches($text, '(--chrome-[a-z-]+|--touch-min)\s*:\s*([^;}]+)')) {
                $token = $m.Groups[1].Value
                $value = $m.Groups[2].Value.Trim()
                if (-not $seen.ContainsKey($token)) { $seen[$token] = @{} }
                $seen[$token][$name] = $value
            }
        }
        Assert-True ($seen.Count -ge 9) "expected the shared chrome tokens, found $($seen.Count)"
        $findings = @()
        foreach ($token in $seen.Keys) {
            $values = @($seen[$token].Values | Sort-Object -Unique)
            if ($values.Count -gt 1) {
                $detail = ($seen[$token].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
                $findings += "$token differs between UIs: $detail"
            }
        }
        Assert-NoFinding $findings 'a chrome token that differs makes the copied block impossible to keep identical'
    }
}

Describe 'static provisioned pages use the deployment language' {
    It 'renders the real Squid page for each enabled locale without changing its URL macro' {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force -DisableNameChecking
        $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
            (Join-Path $script:RepoRoot 'globalization/locale-manifest.json'))) -AsHashtable
        $source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/vmconfig/caching-proxy-service.base.user-data'))
        Assert-True ($source.Contains('data-yuruna-static-locale')) 'the shipped seed has no registered static page'
        $macroCount = [regex]::Matches($source, '%U').Count
        Assert-True ($macroCount -gt 0) 'the shipped Squid page has no original URL macro'
        foreach ($tag in @($manifest.locales.Keys | Where-Object { $manifest.locales[$_].status -in @('supported', 'pseudo') })) {
            $html = ConvertTo-ProvisionedCatalogHtml -Content $source -RepoRoot $script:RepoRoot -Language $tag -AllowPseudoLocale
            Assert-True ($html.Contains('<html lang="' + $tag + '" dir="' + $manifest.locales[$tag].direction + '">')) "$tag was not applied at provisioning"
            Assert-False ($html.Contains('data-yuruna-static-locale')) 'the untranslated static marker survived provisioning'
            Assert-Equal $macroCount ([regex]::Matches($html, '%U').Count) 'localization changed the Squid URL macro'
        }
        $closed = ConvertTo-ProvisionedCatalogHtml -Content $source -RepoRoot $script:RepoRoot -Language 'qps-Plocm'
        Assert-True ($closed.Contains('<html lang="en-US" dir="ltr">')) 'a normal deployment enabled a pseudo locale'
    }
}

Describe 'product globalization acceptance' {
    It 'globalization acceptance: every generated page locale and state' {
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/status/globalization-pages.test.js' -Argument @('generated')
    }
    It 'globalization acceptance: generated page headers cache and CSP' {
        Invoke-ProductGlobalizationCheck -Kind Go -Path 'test/extension/caching-proxy-service'
        Invoke-ProductGlobalizationCheck -Kind Go -Path 'test/extension/caching-proxy-parser-service'
    }
    It 'globalization acceptance: all surfaces expanded and mirrored locales' {
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/status/globalization-pages.test.js'
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/extension/ui-pages.test.js'
    }
    It 'globalization acceptance: capability off keyboard IME and hostile bidi' {
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/status/yuruna.common.test.js'
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/extension/ui-pages.test.js'
    }
}
