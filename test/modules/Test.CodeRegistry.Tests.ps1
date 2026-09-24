<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42b58e0c-4d71-4936-a2f5-91c30d6b7e48
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization codes registry contract pester
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
    Keep every stable code declared, carried by each runtime that claims it,
    and renderable in a reader's language.
.DESCRIPTION
    A code is what crosses a boundary. The sentence a reader sees is rendered
    from it at the last moment, where the reader is; the code itself is one
    spelling in every language, and a surface branches on it.

    That only works while all the surfaces agree on the spelling, and until now
    nothing said what the spellings were. `sequence_paused_waiting_resume` is a
    bare literal in four shipped files across three languages; the repository
    access states are bare literals in four more. A code added on one side and
    forgotten on another does not fail: the surface that missed it treats the
    state as unknown, which is indistinguishable from a state nobody has
    reported yet.

    So the registry declares them, and this suite checks the declaration
    against the tree in both directions -- every consumer really carries the
    literal, and every code a reader can see really has a message to render.

    Run: Invoke-Pester -Path test/modules/Test.CodeRegistry.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:RegistryPath = Join-Path $script:RepoRoot 'globalization/manifests/code-registry.json'
$script:Registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:RegistryPath))
$script:AffectedMapPath = Join-Path $script:RepoRoot 'globalization/generated/affected-slice-map.json'

# Every catalog key the project declares, for checking what a code renders as.
$script:CatalogKeys = @(
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'globalization/catalogs/en-US') -Filter '*.json' -File)) {
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName))
        $doc.messages.PSObject.Properties.Name
    })
}

Describe 'every stable code is declared once and spelled the same everywhere' {

    It 'declares codes in the shape a code has to take' {
        # A code carries no word a translator would touch, and no capital that
        # a case-insensitive comparison somewhere could fold into another code.
        $findings = @()
        $seen = @{}
        foreach ($c in $script:Registry.codes) {
            $code = [string]$c.code
            if ($code -cnotmatch '^[a-z][a-z0-9_.]*$') {
                $findings += "'$code' is not lower-case, underscore-or-dot separated"
            }
            if ($seen.ContainsKey($code)) { $findings += "'$code' is declared twice" }
            $seen[$code] = $true
            if (-not $c.means) { $findings += "'$code' has no meaning recorded; a reader of this file cannot tell what it asserts" }
            if (-not $c.namespace) { $findings += "'$code' has no namespace" }
            if ([string]$c.wireCode -cnotmatch '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$') {
                $findings += "'$code' has no namespaced wireCode"
            }
            if (-not $c.owner) { $findings += "'$code' has no owner" }
            if ($c.schemaVersion -cne $script:Registry.codeSchemaVersion) {
                $findings += "'$code' uses schema '$($c.schemaVersion)', not '$($script:Registry.codeSchemaVersion)'"
            }
            if ($c.lifecycle -notin @('active', 'deprecated')) {
                $findings += "'$code' has invalid lifecycle '$($c.lifecycle)'"
            }
            if ($c.lifecycle -eq 'deprecated' -and
                (-not $c.replacedBy -or -not $c.deprecatedIn -or -not $c.removeAfterRelease -or -not $c.removeAfterDate)) {
                $findings += "'$code' is deprecated without a replacement and finite removal window"
            }
            if (@($c.producedBy).Count -eq 0) { $findings += "'$code' names no producer, so nothing can ever emit it" }
        }
        Assert-True ($script:Registry.codes.Count -ge 5) 'the registry declares too few codes to describe the surface'
        Assert-NoFinding $findings 'a declared code is not in the shape a code contract needs'
    }

    It 'never reuses a retired wire code' {
        $active = @($script:Registry.codes | ForEach-Object { [string]$_.wireCode })
        $retired = @($script:Registry.retiredCodes | ForEach-Object { [string]$_ })
        $findings = @()
        foreach ($code in $retired) {
            if ($code -cnotmatch '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$') {
                $findings += "retired code '$code' is not namespaced"
            }
            if ($active -ccontains $code) { $findings += "retired code '$code' was reused" }
        }
        Assert-NoFinding $findings 'a retired semantic identity became a new condition'
    }

    It 'has a literal-proven generated edge for every runtime it names' {
        # The affected-slice generator scans exact string literals after
        # removing comments and accepts either the deployed runtime code or its
        # composite registry identity. Reading its evidence here prevents a
        # comment-only declaration or a hard-coded matchCount from looking real.
        $findings = @()
        $map = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:AffectedMapPath))
        foreach ($c in $script:Registry.codes) {
            foreach ($role in @('producer', 'consumer')) {
                $property = if ($role -eq 'producer') { 'producedBy' } else { 'consumedBy' }
                foreach ($rel in @($c.$property)) {
                    if (-not $rel) { continue }
                    $edgeId = "code:$($c.wireCode):$role`:$rel"
                    $edge = @($map.consumers | Where-Object id -CEQ $edgeId)
                    if ($edge.Count -ne 1) {
                        $findings += "'$($c.wireCode)' has no unique generated $role edge for $rel"
                    } elseif ([int]$edge[0].matchCount -lt 1) {
                        $findings += "'$($c.wireCode)' claims $rel, but no exact runtime/wire literal was found"
                    }
                }
            }
        }
        Assert-NoFinding $findings 'a runtime does not carry a code the registry says it does'
    }

    It 'renders every reader-facing code from a message that exists' {
        # A code whose key no catalog declares would reach a page and render as
        # the key name, in the middle of otherwise translated text.
        $findings = @()
        foreach ($c in $script:Registry.codes) {
            $key = [string]$c.rendersAs
            if (-not $key) { continue }
            if ($script:CatalogKeys -notcontains $key) {
                $findings += "'$($c.code)' renders as '$key', which no catalog declares"
            }
        }
        Assert-NoFinding $findings 'a code a reader can see has no message behind it'
    }

    It 'says plainly which codes a reader never sees' {
        # An empty rendersAs is a statement, not an omission: this code is
        # machine-only. Making that explicit is what stops the next person
        # adding a sentence for it in one surface and not the others.
        $machineOnly = @($script:Registry.codes | Where-Object { -not $_.rendersAs })
        Assert-True ($machineOnly.Count -ge 1) `
            'every code claims a rendered message; that is unlikely, so check whether one is simply missing a key'
        foreach ($c in $machineOnly) {
            Assert-True ([bool]$c.means) "'$($c.code)' is machine-only and does not say what it means"
        }
    }
}

Describe 'the codes the tree ships are the codes the registry knows' {

    It 'declares the pause code every surface branches on' {
        # The one code that already crosses all three runtimes. If the registry
        # can describe this, it can describe the rest.
        $pause = @($script:Registry.codes | Where-Object { $_.code -eq 'sequence_paused_waiting_resume' })
        Assert-Equal -Expected 1 -Actual $pause.Count 'the pause code is not declared'
        $langs = @{}
        foreach ($rel in (@($pause[0].producedBy) + @($pause[0].consumedBy))) {
            switch -Regex ($rel) {
                '\.psm1$|\.ps1$' { $langs['powershell'] = $true }
                '\.go$'          { $langs['go'] = $true }
                '\.js$'          { $langs['javascript'] = $true }
            }
        }
        foreach ($lang in @('powershell', 'go', 'javascript')) {
            Assert-True ($langs.ContainsKey($lang)) "the pause code is not declared for $lang, which does branch on it"
        }
    }

    It 'finds no repository access value the registry has not heard of' {
        # The enumeration most likely to gain a value quietly. Its own
        # documentation lists the set, so the two can be compared.
        $hostGit = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'test/modules/Test.HostGit.psm1'))
        $m = [regex]::Match($hostGit, "AccessState -- (?<set>'[a-z']+(?:\s*\|\s*'[a-z']+)*)")
        Assert-True $m.Success 'the access-state set is no longer documented where this looks for it'

        $documented = @([regex]::Matches($m.Groups['set'].Value, "'([a-z_]+)'") | ForEach-Object { $_.Groups[1].Value })
        $declared = @($script:Registry.codes |
            Where-Object { $_.namespace -eq 'repository_access' } | ForEach-Object { [string]$_.code })

        $findings = @()
        foreach ($v in $documented) {
            if ($declared -notcontains $v) { $findings += "the module documents '$v' and the registry does not declare it" }
        }
        foreach ($v in $declared) {
            if ($documented -notcontains $v) { $findings += "the registry declares '$v' and the module does not document it" }
        }
        Assert-NoFinding $findings 'the access-state enumeration and the code registry disagree'
    }

    It 'declares the cycle events a consumer off the host reads' {
        $events = @($script:Registry.codes | Where-Object { $_.namespace -eq 'cycle_event' })
        Assert-True ($events.Count -ge 2) 'the step boundaries are not declared'
        foreach ($e in $events) {
            Assert-True ($e.code -cmatch '^step\.(start|end)$') `
                "'$($e.code)' is not one of the step boundaries this namespace is for"
        }
    }
}
