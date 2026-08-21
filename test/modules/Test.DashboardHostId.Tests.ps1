<#PSScriptInfo
.VERSION 2026.08.21
.GUID 42d2490f-e2d9-4303-a287-fa13182fb811
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test dashboard host id guid grafana pester
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
    Guards how the Yuruna hosts dashboard shows a host id, and that the proxy
    is seeded with the same dashboard the repo holds.
.DESCRIPTION
    Three claims, each one a way the panels can lie or break silently.

    The first is what a cell shows. Every Host ID surface shows the id's first
    8 characters -- enough to tell a dozen near-identical 42-prefixed ids apart
    -- and reveals the full one, GUID-formatted, from the cell's own menu. A
    menu needs two entries to BE a menu: with one link a Grafana table cell
    navigates on click instead of opening anything, and the id would never be
    readable.

    The second is the trap underneath the first. A Grafana data link
    interpolates a field's DISPLAYED value, so a link built from the Host ID
    cell now carries 8 characters -- and /go/host answers "missing host" for
    it. Every link in those panels must therefore read the hidden full-id
    column instead, which is what the aggregator exports hostIdDashed for.
    This is asserted rather than reviewed, because the failure is a link that
    still looks right in the JSON.

    The third is that the proxy serves this file. cloud-init carries an inline
    copy and writes it at build time; a correction that lands in only one of
    the two makes a rebuilt VM disagree with the repo and with every proxy
    Sync-PoolDashboardOnProxy has pushed to.

    Throw-based assertions, and no service is started: these are the files the
    VM is built from.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:DashboardPath = Join-Path $repoRoot 'test/extension/pool-aggregator-service/grafana-pool-dashboard.json'
$script:SeedPath      = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data'
$script:DashboardText = [System.IO.File]::ReadAllText($script:DashboardPath).Replace("`r`n", "`n")
$script:Dashboard     = $script:DashboardText | ConvertFrom-Json

# The two tables and the timeline, by panel id: the three panels that put a
# host id in front of an operator.
$script:PanelPoolHosts      = 6
$script:PanelTimeline       = 7
$script:PanelExtensionHosts = 17

function Get-Panel {
    param([Parameter(Mandatory)][int]$Id)
    $p = @($script:Dashboard.panels | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if (-not $p) { throw "panel $Id is missing from the dashboard" }
    return $p
}

# The property list a field override carries, by the column it matches.
function Get-Override {
    param([Parameter(Mandatory)]$Panel, [Parameter(Mandatory)][string]$Column)
    $o = @($Panel.fieldConfig.overrides | Where-Object { $_.matcher.id -eq 'byName' -and $_.matcher.options -eq $Column }) | Select-Object -First 1
    if (-not $o) { throw "panel $($Panel.id) has no override for column '$Column'" }
    return $o
}

function Get-OverrideProperty {
    param([Parameter(Mandatory)]$Override, [Parameter(Mandatory)][string]$Id)
    $p = @($Override.properties | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if (-not $p) { throw "override for '$($Override.matcher.options)' has no '$Id' property" }
    return $p.value
}

# The inline copy cloud-init writes to /var/lib/grafana/dashboards/pool.json,
# lifted back out of the YAML block scalar it lives in.
function Get-SeededDashboard {
    $lines = [System.IO.File]::ReadAllText($script:SeedPath).Replace("`r`n", "`n") -split "`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '- path: /var/lib/grafana/dashboards/pool.json') { $start = $i; break }
    }
    if ($start -lt 0) { throw "the seed does not write /var/lib/grafana/dashboards/pool.json" }
    $j = $start
    while ($lines[$j].Trim() -ne 'content: |') { $j++ }
    $j++
    $indent = $lines[$j].Length - $lines[$j].TrimStart().Length
    $body = [System.Collections.Generic.List[string]]::new()
    while ($j -lt $lines.Count) {
        $line = $lines[$j]
        if ($line.Trim() -and (($line.Length - $line.TrimStart().Length) -lt $indent)) { break }
        $body.Add($(if ($line.Trim()) { $line.Substring($indent) } else { '' }))
        $j++
    }
    return (($body -join "`n").TrimEnd("`n") + "`n")
}
}

Describe 'the Host ID a dashboard panel shows' {

    It 'shows the first 8 characters in both tables' {
        foreach ($id in @($script:PanelPoolHosts, $script:PanelExtensionHosts)) {
            $mappings = Get-OverrideProperty -Override (Get-Override -Panel (Get-Panel -Id $id) -Column 'Host ID') -Id 'mappings'
            $regex = @($mappings | Where-Object { $_.type -eq 'regex' }) | Select-Object -First 1
            Assert-True ($null -ne $regex) -Because "panel $id must map the Host ID cell to a short id"
            # Asserted by RUNNING the mapping, not by matching its text: what the
            # cell shows is the only thing an operator can read off the panel.
            $full = '426d17ef0b88426b922180dad1a9e921'
            $shown = [regex]::Replace($full, $regex.options.pattern, ($regex.options.result.text -replace '\$(\d)', '$$$1'))
            Assert-Equal -Expected '426d17ef' -Actual $shown -Because "panel $id must show 8 characters"
        }
    }

    It 'labels each timeline row with the same 8 characters' {
        $t = @((Get-Panel -Id $script:PanelTimeline).transformations | Where-Object { $_.id -eq 'renameByRegex' }) | Select-Object -First 1
        Assert-True ($null -ne $t) -Because 'the timeline renames its series to a readable row label'
        $full = '426d17ef0b88426b922180dad1a9e921'
        $shown = [regex]::Replace($full, $t.options.regex, ($t.options.renamePattern -replace '\$(\d)', '$$$1'))
        Assert-Equal -Expected '426d17ef' -Actual $shown -Because 'a timeline row is labelled with the short id'
    }

    It 'reveals the full GUID-formatted id from the cell menu' {
        # Two entries or it is not a menu: a Grafana table cell with ONE data link
        # navigates on click, and the id would never be shown at all.
        foreach ($id in @($script:PanelPoolHosts, $script:PanelExtensionHosts)) {
            $links = @(Get-OverrideProperty -Override (Get-Override -Panel (Get-Panel -Id $id) -Column 'Host ID') -Id 'links')
            Assert-True ($links.Count -ge 2) -Because "panel $id's Host ID cell must open a menu, not follow one link"
            Assert-Equal -Expected '${__data.fields.hostIdDashed}' -Actual $links[0].title -Because "panel $id must name the full id first"
            Assert-Equal -Expected '#' -Actual $links[0].url -Because "panel $id's id entry is text to copy and must navigate nowhere"
        }
        $tl = @((Get-Panel -Id $script:PanelTimeline).fieldConfig.defaults.links)
        Assert-Equal -Expected '${__field.labels.hostIdDashed}' -Actual $tl[0].title -Because 'the timeline names the full id first'
        Assert-Equal -Expected '#' -Actual $tl[0].url -Because "the timeline's id entry must navigate nowhere"
    }

    It 'never builds a link out of the shortened cell' {
        # The trap: a data link interpolates a field's DISPLAYED value, so
        # ${__data.fields["Host ID"]} now carries 8 characters and /go/host
        # answers "missing host" for it. Links read the hidden full-id column.
        foreach ($id in @($script:PanelPoolHosts, $script:PanelExtensionHosts)) {
            $panel = Get-Panel -Id $id
            foreach ($ov in @($panel.fieldConfig.overrides)) {
                foreach ($prop in @($ov.properties | Where-Object { $_.id -eq 'links' })) {
                    foreach ($link in @($prop.value)) {
                        Assert-True ([string]$link.url -notmatch '__data\.fields\[\s*\\?"Host ID') `
                            -Because "panel ${id}: '$($link.title)' interpolates the shortened Host ID cell"
                    }
                }
            }
        }
    }

    It 'takes the id it links a host by from the label the collector exports' {
        # hostIdDashed is exported per host beside hostId; a panel that hides it
        # must still keep it in the frame, or every link above resolves empty.
        foreach ($id in @($script:PanelPoolHosts, $script:PanelExtensionHosts)) {
            $panel = Get-Panel -Id $id
            $hidden = Get-OverrideProperty -Override (Get-Override -Panel $panel -Column 'hostIdDashed') -Id 'custom.hidden'
            Assert-True ([bool]$hidden) -Because "panel $id must hide the full-id column it links from"
            $organize = @($panel.transformations | Where-Object { $_.id -eq 'organize' }) | Select-Object -First 1
            Assert-True ($null -ne $organize) -Because "panel $id organizes its columns"
            Assert-True (-not $organize.options.excludeByName.hostIdDashed) -Because "panel $id must not drop the column its links read"
        }
    }
}

Describe 'the dashboard the proxy is seeded with' {

    It 'is byte-identical to the canonical file in the repo' {
        # cloud-init writes the inline copy once, at build time; the repo file is
        # what Sync-PoolDashboardOnProxy pushes to a running proxy. A correction
        # in one of the two leaves a rebuilt VM disagreeing with every other.
        Assert-Equal -Expected $script:DashboardText -Actual (Get-SeededDashboard) `
            -Because 'the seed''s inline pool.json must match grafana-pool-dashboard.json exactly'
    }

    It 'still carries the placeholder cloud-init rewrites into an aggregator URL' {
        Assert-True ($script:DashboardText -match 'AGGREGATOR_BASE_PLACEHOLDER') `
            -Because 'every /go/ link is built from the aggregator variable the guest fills in'
    }
}
