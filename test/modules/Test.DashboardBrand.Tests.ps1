<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42536ec8-4d7e-4727-b52e-55f7f0ca8688
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna caching proxy grafana dashboard brand version pester
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
    Guards the brand banner the caching-proxy VM stamps into its Grafana
    dashboards, and the identity the host seeds it with.
.DESCRIPTION
    Two claims are worth defending, and both are about a dashboard telling the
    truth about where it came from.

    The first is the identity itself. A lab that runs the public and the private
    repository side by side can hold two proxies whose dashboards are otherwise
    indistinguishable, and a name resolved by a different rule than the status
    pages use would put two different answers in front of one operator. So the
    derivation is asserted against the same cases the pages' own rule produces.

    The second is that the banner costs one line and nothing else. It spans the
    full grid width above the first row, so every panel on the board moves down
    by its height and none of them is resized -- including on the community
    board, whose layout is fetched at build time and is not ours to predict.
    The panel autofit stacks from below the banner for the same reason, and the
    two are asserted together: they write the same file.

    The guest script is not restated here: it is lifted out of the cloud-init
    seed and executed, so these run the code the VM actually gets. Same for the
    two seeded placeholders -- a banner is only as correct as the values the three
    New-VM.ps1 scripts pass, and a host that forgets one ships an unbranded VM.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.DashboardBrand.Tests.ps1
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = $repoRoot
$script:SeedPath = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data'

# The banner's geometry, restated from the guest script so a change to either
# side has to be a deliberate change to both.
$script:GridW  = 24
$script:BrandW = $script:GridW
$script:BrandH = 2
# Ordinary spaces collapse in rendered HTML, so the parts are held apart by
# non-breaking ones. The guest script writes them as a \u00a0 escape.
$script:Separator = [string][char]0x00A0 * 4

Import-Module (Join-Path $here 'Test.FrameworkSource.psm1') -Force

# Lift one write_files body out of a cloud-init seed. The block scalar's own
# indentation is stripped, which is what the guest receives.
function Get-SeedFileContent {
    param([Parameter(Mandatory)][string]$SeedPath, [Parameter(Mandatory)][string]$GuestPath)

    $lines = [System.IO.File]::ReadAllLines($SeedPath)
    $i = 0
    while ($i -lt $lines.Count -and $lines[$i].Trim() -ne "- path: $GuestPath") { $i++ }
    if ($i -ge $lines.Count) { throw "No write_files entry for '$GuestPath' in $SeedPath" }
    while ($i -lt $lines.Count -and $lines[$i] -notmatch 'content:\s*\|') { $i++ }
    if ($i -ge $lines.Count) { throw "The write_files entry for '$GuestPath' has no block scalar" }
    $i++

    $indent = $lines[$i].Length - $lines[$i].TrimStart().Length
    $body = [System.Collections.Generic.List[string]]::new()
    while ($i -lt $lines.Count) {
        if ($lines[$i].Trim() -eq '') { $body.Add(''); $i++; continue }
        if (($lines[$i].Length - $lines[$i].TrimStart().Length) -lt $indent) { break }
        $body.Add($lines[$i].Substring($indent))
        $i++
    }
    return ($body -join "`n")
}

# python3 runs the guest script here exactly as the VM would. It is the same
# interpreter the proxy's own dashboard tooling needs, so a host without one
# cannot check this; say so rather than passing silently.
$script:Python = (Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1)

$script:WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-brand-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:WorkRoot | Out-Null
$script:BranderPath = Join-Path $script:WorkRoot 'yuruna-brand-dashboards.py'
[System.IO.File]::WriteAllText($script:BranderPath,
    (Get-SeedFileContent -SeedPath $script:SeedPath -GuestPath '/usr/local/bin/yuruna-brand-dashboards.py'))

# The autofit rewrites the same file the banner is stamped into, so it is run
# here too. Its counts come from Prometheus and Loki, which no test host has, so
# the driver replaces the one function that reaches for them and leaves every
# geometry decision to the guest script itself.
$script:FitterPath = Join-Path $script:WorkRoot 'yuruna-fit-pool-dashboard.py'
[System.IO.File]::WriteAllText($script:FitterPath,
    (Get-SeedFileContent -SeedPath $script:SeedPath -GuestPath '/usr/local/bin/yuruna-fit-pool-dashboard.py'))
$script:FitDriverPath = Join-Path $script:WorkRoot 'drive-fitter.py'
[System.IO.File]::WriteAllText($script:FitDriverPath, @'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("fit", sys.argv[1])
fit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fit)
fit.DASHBOARD = sys.argv[2]
hosts = int(sys.argv[3])
fit.query = lambda url, expr: hosts
sys.exit(fit.main())
'@)

function Invoke-Fitter {
    param(
        [Parameter(Mandatory)][string]$DashboardPath,
        [int]$Hosts = 3
    )
    & $script:Python.Source $script:FitDriverPath $script:FitterPath $DashboardPath $Hosts 2>&1 | Out-String
}

# Run the guest script over a directory of dashboards, with the identity it
# would read from the seeded env file.
function Invoke-Brander {
    param(
        [Parameter(Mandatory)][string]$DashboardDir,
        [string]$Name = 'Yurunadev',
        [string]$Version = '2026.09.13',
        [switch]$NoEnvFile
    )
    $envFile = Join-Path $DashboardDir '..' | Join-Path -ChildPath 'brand.env'
    if (-not $NoEnvFile) {
        [System.IO.File]::WriteAllText($envFile,
            "YURUNA_BRAND_NAME='$Name'`nYURUNA_BRAND_VERSION='$Version'`n")
    }
    $env:YURUNA_DASHBOARD_DIR = $DashboardDir
    $env:YURUNA_BRAND_ENV     = $envFile
    try { & $script:Python.Source $script:BranderPath 2>&1 | Out-String }
    finally {
        Remove-Item Env:\YURUNA_DASHBOARD_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\YURUNA_BRAND_ENV -ErrorAction SilentlyContinue
    }
}

# One dashboard directory per test, so nothing carries state between them.
# Named Get-, not New-: a New- helper is asked to support -WhatIf, which a
# fixture builder has no business carrying.
function Get-DashboardFixture {
    param([Parameter(Mandatory)][hashtable]$Dashboard)
    $dir = Join-Path $script:WorkRoot ([guid]::NewGuid().ToString('N'))
    $dashboards = Join-Path $dir 'dashboards'
    New-Item -ItemType Directory -Force -Path $dashboards | Out-Null
    foreach ($name in $Dashboard.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $dashboards "$name.json"), $Dashboard[$name])
    }
    return $dashboards
}

# The dashboards this VM actually serves: two inlined in the seed, one held
# canonically in the repo and inlined byte-identically alongside them.
$script:RealDashboards = [ordered]@{
    'pool'         = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'test/extension/pool-aggregator-service/grafana-pool-dashboard.json'))
    'cache-health' = Get-SeedFileContent -SeedPath $script:SeedPath -GuestPath '/var/lib/grafana/dashboards/cache-health.json'
    'squid'        = Get-SeedFileContent -SeedPath $script:SeedPath -GuestPath '/var/lib/grafana/dashboards/squid.json'
}

# Every panel's place on the grid, keyed by id: what must be identical before
# and after a stamp, one band lower.
function Get-Layout {
    param([Parameter(Mandatory)]$Dashboard)
    $layout = [ordered]@{}
    foreach ($panel in $Dashboard.panels) {
        $layout["$($panel.id)"] = "$($panel.gridPos.x),$($panel.gridPos.y),$($panel.gridPos.w),$($panel.gridPos.h)"
    }
    return $layout
}

# Every grid cell a panel claims, so an overlap is a duplicate key rather than
# a geometry argument restated in the test.
function Get-GridOverlap {
    param([Parameter(Mandatory)]$Dashboard)
    $cells = @{}
    $clashes = [System.Collections.Generic.List[string]]::new()
    foreach ($panel in $Dashboard.panels) {
        for ($y = $panel.gridPos.y; $y -lt ($panel.gridPos.y + $panel.gridPos.h); $y++) {
            for ($x = $panel.gridPos.x; $x -lt ($panel.gridPos.x + $panel.gridPos.w); $x++) {
                if ($cells.ContainsKey("$x,$y")) { $clashes.Add("panels $($cells["$x,$y"]) and $($panel.id) both claim $x,$y") }
                $cells["$x,$y"] = $panel.id
            }
        }
    }
    return $clashes
}

function Get-BrandPanel {
    param([Parameter(Mandatory)]$Dashboard)
    return @($Dashboard.panels | Where-Object {
        $_.type -eq 'text' -and $_.options -and "$($_.options.content)" -match '<!-- yuruna-brand -->'
    }) | Select-Object -First 1
}
}

AfterAll {
    if ($script:WorkRoot -and (Test-Path -LiteralPath $script:WorkRoot)) {
        Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'the brand banner is one line across the top of the dashboards this VM serves' {

    It 'spans the full width above everything the dashboard already had' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        $dir = Get-DashboardFixture -Dashboard $script:RealDashboards
        Invoke-Brander -DashboardDir $dir | Out-Null

        foreach ($name in $script:RealDashboards.Keys) {
            $doc   = Get-Content -Raw (Join-Path $dir "$name.json") | ConvertFrom-Json
            $brand = Get-BrandPanel -Dashboard $doc
            Assert-True ($null -ne $brand) -Because "$name must carry the banner"
            Assert-Equal -Expected 0 -Actual $brand.gridPos.x -Because "$name's banner must start at the left edge"
            Assert-Equal -Expected 0 -Actual $brand.gridPos.y -Because "$name's banner must sit above everything else"
            Assert-Equal -Expected $script:BrandW -Actual $brand.gridPos.w -Because "$name's banner must span the grid"
            Assert-Equal -Expected $script:BrandH -Actual $brand.gridPos.h -Because "$name's banner must be one line tall"

            $intruders = @($doc.panels | Where-Object { $_.id -ne $brand.id -and $_.gridPos.y -lt $script:BrandH })
            Assert-Equal -Expected 0 -Actual $intruders.Count `
                -Because "$name keeps $($intruders.Count) panel(s) inside the banner's own band"

            # Grafana reflows a grid whose panels collide, which would undo the
            # layout the shift was careful to preserve.
            $clashes = @(Get-GridOverlap -Dashboard $doc)
            Assert-Equal -Expected 0 -Actual $clashes.Count -Because "$name overlaps: $($clashes -join '; ')"
        }
    }

    It 'moves the whole layout down by the banner and resizes none of it' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # The banner takes a band of its own rather than a corner of the first
        # row, so the only thing it may do to a dashboard is move it down.
        $dir = Get-DashboardFixture -Dashboard $script:RealDashboards
        $before = @{}
        foreach ($name in $script:RealDashboards.Keys) {
            $before[$name] = Get-Layout -Dashboard (Get-Content -Raw (Join-Path $dir "$name.json") | ConvertFrom-Json)
        }

        Invoke-Brander -DashboardDir $dir | Out-Null

        foreach ($name in $script:RealDashboards.Keys) {
            $after = Get-Layout -Dashboard (Get-Content -Raw (Join-Path $dir "$name.json") | ConvertFrom-Json)
            foreach ($id in $before[$name].Keys) {
                $was = $before[$name][$id] -split ','
                $expected = "$($was[0]),$([int]$was[1] + $script:BrandH),$($was[2]),$($was[3])"
                Assert-Equal -Expected $expected -Actual $after[$id] `
                    -Because "$name's panel $id must keep its column, width and height, one band lower"
            }
        }
    }

    It 'reads as one line: name, version and provenance side by side' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # A line that broke would need a taller banner to be legible, which is
        # the whole cost the layout was chosen to avoid.
        $dir = Get-DashboardFixture -Dashboard $script:RealDashboards
        Invoke-Brander -DashboardDir $dir -Name 'Yurunadev' -Version '2026.09.13' | Out-Null

        foreach ($name in $script:RealDashboards.Keys) {
            $doc = Get-Content -Raw (Join-Path $dir "$name.json") | ConvertFrom-Json
            $content = "$((Get-BrandPanel -Dashboard $doc).options.content)"
            # The sentinel is an HTML comment on its own line: it renders to
            # nothing, so it is not part of the line being measured.
            $rendered = ($content -replace '(?s)^.*?-->\s*', '')
            Assert-True ($rendered -notmatch '[\r\n]') -Because "$name's banner must be a single line: got [$rendered]"
            Assert-Equal -Expected ("**Yurunadev**" + $script:Separator + '`v2026.09.13`') -Actual $rendered `
                -Because "$name's banner must hold the name and version apart with non-breaking spaces"
        }
    }
}

Describe 'the brand banner says which dashboards are not ours' {

    It 'marks a community dashboard as unmodified upstream content, and leaves ours unmarked' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # The fixture carries the uid the installed board ACTUALLY has. The
        # install step rewrites the community board's uid into the yuruna-
        # namespace to give it a stable identity, so a uid-prefix rule matches
        # every dashboard on the VM and marks none of them. Only the tag the
        # installer writes distinguishes them, and only a fixture that mirrors
        # the deployed shape can prove it.
        $community = @{
            uid    = 'yuruna-zot-official'
            title  = 'Zot (official, Grafana ID 20501)'
            tags   = @('yuruna', 'community')
            panels = @(@{ id = 1; type = 'stat'; gridPos = @{ h = 4; w = 24; x = 0; y = 0 } })
        } | ConvertTo-Json -Depth 8
        $fixture = [ordered]@{ 'squid' = $script:RealDashboards['squid']; 'zot-official' = $community }

        $dir = Get-DashboardFixture -Dashboard $fixture
        Invoke-Brander -DashboardDir $dir | Out-Null

        $ours = Get-BrandPanel -Dashboard (Get-Content -Raw (Join-Path $dir 'squid.json') | ConvertFrom-Json)
        $theirs = Get-BrandPanel -Dashboard (Get-Content -Raw (Join-Path $dir 'zot-official.json') | ConvertFrom-Json)

        Assert-True ($null -ne $theirs) 'the community dashboard still gets a banner'
        Assert-True ("$($theirs.options.content)" -match [regex]::Escape($script:Separator + '_Community dashboard, unmodified_')) `
            'the community banner says the board is unmodified upstream content, on the same line as the rest'
        Assert-True ("$($theirs.options.content)" -notmatch '(?m)^_Community') `
            'the note must not be a line of its own'
        Assert-True ("$($ours.options.content)" -notmatch 'Community') `
            'a seeded dashboard is not labeled as community content'
    }

    It 'reads the tag the installer writes, not the uid or the filename' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # Same uid namespace, same filename shape, opposite provenance. If the
        # rule ever drifts back to inspecting either one, exactly one of these
        # two assertions fails.
        $tagged = @{
            uid = 'yuruna-something'; title = 'Upstream'; tags = @('yuruna', 'community')
            panels = @(@{ id = 1; type = 'stat'; gridPos = @{ h = 4; w = 24; x = 0; y = 0 } })
        } | ConvertTo-Json -Depth 8
        $untagged = @{
            uid = 'yuruna-something-else'; title = 'Ours'; tags = @('yuruna')
            panels = @(@{ id = 1; type = 'stat'; gridPos = @{ h = 4; w = 24; x = 0; y = 0 } })
        } | ConvertTo-Json -Depth 8

        $dir = Get-DashboardFixture -Dashboard ([ordered]@{ 'a-board' = $tagged; 'b-board' = $untagged })
        Invoke-Brander -DashboardDir $dir | Out-Null

        $a = Get-BrandPanel -Dashboard (Get-Content -Raw (Join-Path $dir 'a-board.json') | ConvertFrom-Json)
        $b = Get-BrandPanel -Dashboard (Get-Content -Raw (Join-Path $dir 'b-board.json') | ConvertFrom-Json)
        Assert-True ("$($a.options.content)" -match 'Community dashboard, unmodified') 'the tagged board is marked'
        Assert-True ("$($b.options.content)" -notmatch 'Community') 'the untagged board is not'
    }

    It 'the seed tags the community board it installs' {
        # The stamper can only read a tag the installer writes. Assert the two
        # halves agree, in the seed itself, so they cannot drift apart silently
        # -- which is exactly how the uid rule shipped marking nothing.
        $seed = [System.IO.File]::ReadAllText($script:SeedPath)
        Assert-True ($seed -match "\['yuruna', 'community'\]") `
            'the zot rebinder tags the board it installs as community content'
        Assert-True ($seed -match 'COMMUNITY_TAG = "community"') `
            'the brand stamper looks for that same tag'
    }
}

Describe 'the brand banner is safe to re-run' {

    It 'rewrites nothing on a dashboard that already carries it' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # The timer fires every 15 minutes for the life of the VM. A pass that
        # was not a no-op would push the board another band down each time.
        $dir = Get-DashboardFixture -Dashboard $script:RealDashboards
        Invoke-Brander -DashboardDir $dir | Out-Null
        $first = @{}
        foreach ($name in $script:RealDashboards.Keys) { $first[$name] = Get-Content -Raw (Join-Path $dir "$name.json") }

        foreach ($pass in 1..3) {
            Invoke-Brander -DashboardDir $dir | Out-Null
            foreach ($name in $script:RealDashboards.Keys) {
                Assert-Equal -Expected $first[$name] -Actual (Get-Content -Raw (Join-Path $dir "$name.json")) `
                    -Because "pass $pass rewrote $name; the banner must be idempotent byte for byte"
            }
        }
    }

    It 'refreshes the text without moving anything when the identity changes' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # The version is a variable, not a literal repeated in the assertion.
        # Written twice, the two copies drift the first time the version moves,
        # and the assertion then checks for a string the test never asked for.
        $version = '2026.09.13'

        $dir = Get-DashboardFixture -Dashboard $script:RealDashboards
        Invoke-Brander -DashboardDir $dir -Name 'Yurunadev' -Version $version | Out-Null
        $doc = Get-Content -Raw (Join-Path $dir 'pool.json') | ConvertFrom-Json
        $geometry = (Get-Layout -Dashboard $doc).Values -join '|'

        Invoke-Brander -DashboardDir $dir -Name 'Yuruna' -Version $version | Out-Null
        $doc = Get-Content -Raw (Join-Path $dir 'pool.json') | ConvertFrom-Json

        $content = "$((Get-BrandPanel -Dashboard $doc).options.content)"
        # The boundary matters, not the markup: "Yuruna" must not match inside
        # "Yurunadev", which is the name the banner carried a moment ago. The
        # banner emits the name in bold rather than as a markdown heading -- a
        # heading made it the FIRST heading on every provisioned dashboard, an
        # <h4> with no h1/h2/h3 above it, and the brand name is a label, not a
        # section.
        Assert-True ($content -match 'Yuruna(\*\*|\r|\n|$)') -Because 'the refreshed banner must carry the new name'
        Assert-True ($content -match ('v' + [regex]::Escape($version))) -Because 'the refreshed banner must carry the new version'
        Assert-Equal -Expected $geometry -Actual ((Get-Layout -Dashboard $doc).Values -join '|') `
            -Because 'a text refresh must not move the board a second time'
    }

    It 'stamps nothing rather than an empty identity' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # A seed that could not resolve a name leaves the file absent or its
        # value empty. A banner reading a bare "v" claims an identity nobody
        # can act on; no banner at least says nothing.
        $dir = Get-DashboardFixture -Dashboard $script:RealDashboards
        Invoke-Brander -DashboardDir $dir -NoEnvFile | Out-Null
        $doc = Get-Content -Raw (Join-Path $dir 'pool.json') | ConvertFrom-Json
        Assert-True ($null -eq (Get-BrandPanel -Dashboard $doc)) -Because 'no env file must leave the dashboard untouched'

        $dir = Get-DashboardFixture -Dashboard $script:RealDashboards
        Invoke-Brander -DashboardDir $dir -Name '' | Out-Null
        $doc = Get-Content -Raw (Join-Path $dir 'pool.json') | ConvertFrom-Json
        Assert-True ($null -eq (Get-BrandPanel -Dashboard $doc)) -Because 'an empty name must leave the dashboard untouched'
    }

    It 'omits the version line rather than showing a bare v' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        $dir = Get-DashboardFixture -Dashboard $script:RealDashboards
        Invoke-Brander -DashboardDir $dir -Name 'Yuruna' -Version '' | Out-Null
        $doc = Get-Content -Raw (Join-Path $dir 'pool.json') | ConvertFrom-Json
        $brand = Get-BrandPanel -Dashboard $doc
        Assert-True ($null -ne $brand) -Because 'a missing VERSION must not cost the name too'
        Assert-True ("$($brand.options.content)" -notmatch '`v`') -Because 'an absent version must be absent, not an empty one'
    }
}

Describe 'the brand banner leaves a layout it did not write alone' {

    It 'moves a dashboard that opens with a row header down whole' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # The community Zot dashboard is fetched from grafana.com at build time,
        # so its layout is not ours to predict. A row header spans the full
        # width and leaves nothing beside it; a band above it needs nothing.
        $dir = Get-DashboardFixture -Dashboard @{ 'rowfirst' = @'
{"title":"row first","panels":[
  {"id":1,"type":"row","gridPos":{"x":0,"y":0,"w":24,"h":1}},
  {"id":2,"type":"stat","gridPos":{"x":0,"y":1,"w":12,"h":4}}]}
'@ }
        Invoke-Brander -DashboardDir $dir | Out-Null
        $doc = Get-Content -Raw (Join-Path $dir 'rowfirst.json') | ConvertFrom-Json

        $brand = Get-BrandPanel -Dashboard $doc
        Assert-True ($null -ne $brand) -Because 'the banner must still land'
        Assert-Equal -Expected 0 -Actual $brand.gridPos.y -Because 'the banner takes the top band'
        $row = @($doc.panels | Where-Object { $_.type -eq 'row' })[0]
        Assert-Equal -Expected $script:BrandH -Actual $row.gridPos.y -Because 'the row header moves down whole'
        Assert-Equal -Expected 24 -Actual $row.gridPos.w -Because 'a row header spans the full width'
    }

    It 'leaves a crowded first row at the widths it was written with' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # Twelve two-unit tiles have nothing to give: any of them narrowed shows
        # an ellipsis instead of a number, which is why the banner asks for
        # height it can always have rather than width it sometimes cannot.
        $panels = (0..11 | ForEach-Object {
            '{"id":' + $_ + ',"type":"stat","gridPos":{"x":' + ($_ * 2) + ',"y":0,"w":2,"h":3}}'
        }) -join ','
        $dir = Get-DashboardFixture -Dashboard @{ 'crowded' = '{"title":"crowded","panels":[' + $panels + ']}' }
        Invoke-Brander -DashboardDir $dir | Out-Null
        $doc = Get-Content -Raw (Join-Path $dir 'crowded.json') | ConvertFrom-Json

        Assert-True ($null -ne (Get-BrandPanel -Dashboard $doc)) -Because 'the banner must still land'
        foreach ($p in $doc.panels | Where-Object { $_.type -eq 'stat' }) {
            Assert-Equal -Expected 2 -Actual $p.gridPos.w -Because 'a stat tile must keep the width it was given'
            Assert-Equal -Expected $script:BrandH -Actual $p.gridPos.y -Because 'the row moves down instead'
        }
    }

    It 'leaves a file that is not a dashboard alone' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # The provisioning directory is a directory: anything can be dropped in
        # it, and one bad file must not stop the dashboards beside it.
        $mixed = [ordered]@{ 'junk' = '[1,2,3]'; 'broken' = '{not json'; 'pool' = $script:RealDashboards['pool'] }
        $dir = Get-DashboardFixture -Dashboard $mixed
        Invoke-Brander -DashboardDir $dir | Out-Null

        Assert-Equal -Expected '[1,2,3]' -Actual (Get-Content -Raw (Join-Path $dir 'junk.json')).Trim() `
            -Because 'a JSON file that is not a dashboard must be left as it was'
        Assert-Equal -Expected '{not json' -Actual (Get-Content -Raw (Join-Path $dir 'broken.json')).Trim() `
            -Because 'an unparseable file must be left as it was'
        Assert-True ((Get-Content -Raw (Join-Path $dir 'pool.json')) -match 'yuruna-brand') `
            -Because 'the dashboards beside it must still be branded'
    }
}

Describe 'the panel autofit stacks below the banner' {

    It 'sizes the per-host panels without climbing into the banner or the tiles' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3 is not installed on this host'; return }

        # Two scripts own parts of the same file: the banner takes the top band
        # and moves everything down, the autofit re-stacks the three per-host
        # panels below the summary tiles. An autofit that stacked from a height
        # it had been told rather than one it read would put the tables over the
        # tiles the moment the banner moved them.
        $dir  = Get-DashboardFixture -Dashboard @{ 'pool' = $script:RealDashboards['pool'] }
        $pool = Join-Path $dir 'pool.json'
        Invoke-Brander -DashboardDir $dir | Out-Null
        Invoke-Fitter -DashboardPath $pool | Out-Null

        $doc   = Get-Content -Raw $pool | ConvertFrom-Json
        $brand = Get-BrandPanel -Dashboard $doc
        Assert-Equal -Expected 0 -Actual $brand.gridPos.y -Because 'the autofit must not move the banner'
        $clashes = @(Get-GridOverlap -Dashboard $doc)
        Assert-Equal -Expected 0 -Actual $clashes.Count -Because "the fitted dashboard overlaps: $($clashes -join '; ')"

        # The stack begins where the tiles end, wherever the banner has put them.
        $tiles = @($doc.panels | Where-Object { $_.type -eq 'stat' } |
            ForEach-Object { $_.gridPos.y + $_.gridPos.h } | Sort-Object -Unique)
        $stack = @($doc.panels | Where-Object { $_.id -in 6, 7, 17 } |
            ForEach-Object { $_.gridPos.y } | Sort-Object)
        Assert-Equal -Expected ($tiles[-1]) -Actual $stack[0] `
            -Because 'the per-host stack must start immediately below the summary tiles'
    }
}

Describe 'the seeded identity names the enlistment the VM was built from' {

    It 'derives the name by the rule the status pages use' {
        # buildHostInfo in test/status/yuruna.common.js resolves #header-title
        # from the same URL. These are its cases; the two surfaces are read side
        # by side and may not disagree about which repository they came from.
        $cases = @(
            @{ Url = 'https://github.com/alissonsol/yuruna-fork';      Expected = 'Yuruna-fork' }
            @{ Url = 'https://github.com/alissonsol/yuruna';           Expected = 'Yuruna' }
            @{ Url = 'https://github.com/alissonsol/yuruna.git';       Expected = 'Yuruna' }
            @{ Url = 'https://github.com/alissonsol/yuruna/';          Expected = 'Yuruna' }
            @{ Url = 'git@github.com:alissonsol/yuruna-fork.git';      Expected = 'Yuruna-fork' }
            @{ Url = 'https://github.com/alissonsol/yuruna?ref=main';  Expected = 'Yuruna' }
            @{ Url = 'https://github.com/alissonsol/yuruna#readme';    Expected = 'Yuruna' }
            @{ Url = '';                                              Expected = '' }
            # A '.git' followed by a slash keeps the suffix, because the pages
            # keep it: the suffix is stripped before the trailing slash is, so
            # by then it is no longer at the end. Asserted rather than corrected
            # -- the two surfaces agreeing matters more than either being tidy.
            @{ Url = 'https://github.com/alissonsol/yuruna-fork.git/'; Expected = 'Yuruna-fork.git' }
        )
        foreach ($case in $cases) {
            Assert-Equal -Expected $case.Expected -Actual (ConvertTo-YurunaBrandName -Url $case.Url) `
                -Because "the status pages resolve '$($case.Url)' to '$($case.Expected)'"
        }
    }

    It 'applies the same operations in the same order the status pages do' {
        # The cases above only sample the rule. This is the rule: if
        # buildHostInfo's chain is ever reordered or extended, the sampled
        # answers can still agree while the two surfaces have quietly parted.
        $js = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/status/yuruna.common.js')
        $chain = [regex]::Match($js, "split\(/\[\?#\]/\)\[0\](?<rest>[\s\S]{0,200}?);")
        Assert-True $chain.Success -Because 'buildHostInfo must still resolve the repo name from repoUrl'
        $rest = $chain.Groups['rest'].Value
        # A regex literal's own body can carry an escaped slash (/\/+$/), so the
        # scan has to step over an escape rather than stop at the next slash.
        $order = @([regex]::Matches($rest, "replace\(/(?<pattern>(?:\\.|[^/\\])+)/") |
            ForEach-Object { $_.Groups['pattern'].Value })
        Assert-Equal -Expected '\.git$|\/+$' -Actual ($order -join '|') `
            -Because 'the page strips the .git suffix first and the trailing slashes second; ConvertTo-YurunaBrandName does the same'
        # Taking the last segment is its own statement in the page, past the
        # chain captured above.
        Assert-True ($js -match "split\('/'\)\.pop\(\)") `
            -Because 'the page takes the last path segment'
        Assert-True ($js -match "charAt\(0\)\.toUpperCase\(\)\s*\+\s*\w+\.slice\(1\)") `
            -Because 'the page capitalizes only the first character'
    }

    It 'prefers the configured framework repository over this host git remote' {
        # An operator who points frameworkUrl at one repository while their
        # enlistment tracks another means the first one; the status pages read
        # it in that order too.
        $config = [ordered]@{ repositories = [ordered]@{ frameworkUrl = 'https://github.com/alissonsol/yuruna-fork' } }
        Assert-Equal -Expected 'Yuruna-fork' `
            -Actual (Get-YurunaBrandIdentity -RepoRoot $script:RepoRoot -Config $config).Name `
            -Because 'the configured repository decides the name'
    }

    It 'answers a usable identity where nothing can be resolved' {
        # A seed cannot carry a null. An unbrandable host still has to render.
        $identity = Get-YurunaBrandIdentity -RepoRoot (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')))
        Assert-Equal -Expected 'Yuruna' -Actual $identity.Name -Because 'the name falls back rather than emptying'
        Assert-Equal -Expected '' -Actual $identity.Version -Because 'an unreadable VERSION reports empty, not a guess'
    }

    It 'reduces both halves to what the seed can carry' {
        # Both values land inside single quotes in a shell env file. A quote or
        # a backslash there would end the string and leave the rest of the line
        # running as something else.
        $config = [ordered]@{ repositories = [ordered]@{ frameworkUrl = "https://example.test/yur'una`\dev`n" } }
        $identity = Get-YurunaBrandIdentity -RepoRoot $script:RepoRoot -Config $config
        Assert-True ($identity.Name -notmatch "['`"\\]") -Because "a quote or backslash must not reach the env file: got [$($identity.Name)]"
        Assert-True ($identity.Name -match '^[A-Za-z0-9._-]+$') -Because "the name must be reduced to the repository alphabet: got [$($identity.Name)]"
    }

    It 'answers the same identity every time it is asked' {
        # The derivation reads $LASTEXITCODE after a native git call. A pipeline
        # that stopped git early would leave that reporting on a run git was
        # never allowed to finish, and the name would flip between builds.
        $answers = @(1..5 | ForEach-Object { (Get-YurunaBrandIdentity -RepoRoot $script:RepoRoot).Name }) | Sort-Object -Unique
        Assert-Equal -Expected 1 -Actual $answers.Count -Because "the name must not vary between calls: got [$($answers -join ', ')]"
    }
}

Describe 'every host that builds a cache VM seeds the identity into it' {

    It 'passes both halves from all three New-VM.ps1 scripts' {
        # The banner is only as correct as the values the seed is rendered with,
        # and New-CloudInitUserData throws on a placeholder no caller supplied,
        # so a host that forgets one cannot build a proxy at all.
        foreach ($host_ in @('ubuntu.kvm', 'windows.hyper-v', 'macos.utm')) {
            $path = Join-Path $script:RepoRoot "host/$host_/guest.caching-proxy-service/New-VM.ps1"
            $text = Get-Content -Raw -LiteralPath $path
            foreach ($placeholder in @('YURUNA_BRAND_NAME_PLACEHOLDER', 'YURUNA_BRAND_VERSION_PLACEHOLDER')) {
                Assert-True ($text -match [regex]::Escape($placeholder)) `
                    -Because "$host_ must supply $placeholder or its cache VM cannot be seeded"
            }
            Assert-True ($text -match 'Get-YurunaBrandIdentity') `
                -Because "$host_ must resolve the identity rather than restating the rule"
        }
    }

    It 'carries both placeholders into the seed' {
        $seed = Get-Content -Raw -LiteralPath $script:SeedPath
        foreach ($placeholder in @('YURUNA_BRAND_NAME_PLACEHOLDER', 'YURUNA_BRAND_VERSION_PLACEHOLDER')) {
            Assert-True ($seed -match [regex]::Escape($placeholder)) -Because "the seed must consume $placeholder"
        }
    }

    It 'keeps every brand runcmd entry a command and not a mapping' {
        # A plain YAML scalar ends at the first ": ", so a runcmd line whose
        # message carries one parses as a mapping and never runs. Block scalars
        # are the fix; this is what catches the next one written without.
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking 3>$null
        $seed = (Get-Content -Raw -LiteralPath $script:SeedPath | ConvertFrom-Yaml -Ordered)
        $branding = @($seed.runcmd | Where-Object { "$_" -match 'yuruna-brand-dashboards' })
        Assert-True ($branding.Count -ge 2) -Because 'the seed must both enable the timer and stamp once at build'
        foreach ($entry in $branding) {
            Assert-True ($entry -is [string]) -Because "a runcmd entry must parse as a command: got [$($entry.GetType().Name)]"
        }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
