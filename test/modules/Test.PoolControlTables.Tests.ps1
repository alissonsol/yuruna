<#PSScriptInfo
.VERSION 2026.08.16
.GUID 4293f9e7-91cd-495d-aafa-68e31b1cda6a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool control table sort counter column pester
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
    Guards the sortable tables of the pool-control UI: the counter column, the
    header controls that sort them, and the column count each page's own
    "nothing here" row has to span.
.DESCRIPTION
    Four pages (Assign, Hosts, Pools, Test sets) each pair a static <thead>
    with a script that builds the rows, and the two halves have to agree on
    facts no runtime error reports:

      - a header sorts on a KEY, and the row builder has to publish a value
        under that key -- a typo sorts every row as a blank instead, which
        looks like a table that simply will not sort;
      - a page's empty-state row spans a column count written as a literal,
        which a new column silently makes wrong;
      - the counter column leads every table and is not itself sortable, since
        it numbers positions on screen rather than anything in the row.

    The pages are served by //go:embed out of the daemon, so nothing here runs
    the service: these are the source files it would embed.

    Throw-based Assert-* helpers and every fixture are built in BeforeAll, the
    only scope an It can read: Pester 5 runs file scope and Describe bodies
    during discovery, and nothing they define survives into the run phase.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent (Split-Path -Parent $here)
$web = Join-Path $repo 'test/extension/pool-control-service/server/internal/httpsrv/web'

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-NoFinding {
    param([string[]]$Findings, [string]$Because = '')
    if ($Findings.Count -gt 0) { throw ("$Because`n  " + ($Findings -join "`n  ")) }
}

# One entry per page that carries a sortable table, with the script that builds
# its rows. Hosts sorts from its own comparator (hardware columns are numbers
# read from a second endpoint); the other three go through Y.sortTable.
$script:tables = @(
    @{ Page = 'Assign'; Html = 'index.html'; Script = 'assets/index.js' }
    @{ Page = 'Hosts'; Html = 'hosts.html'; Script = 'assets/hosts.js' }
    @{ Page = 'Pools'; Html = 'pools.html'; Script = 'assets/pools.js' }
    @{ Page = 'Test sets'; Html = 'test-sets.html'; Script = 'assets/test-sets.js' }
) | ForEach-Object {
    $html = Get-Content -Raw -LiteralPath (Join-Path $web $_.Html)
    $heads = [regex]::Matches($html, '(?s)<thead>(.*?)</thead>')
    [pscustomobject]@{
        Page   = $_.Page
        Html   = $html
        Heads  = @($heads | ForEach-Object { $_.Groups[1].Value })
        Script = (Get-Content -Raw -LiteralPath (Join-Path $web $_.Script))
    }
}
$script:common = Get-Content -Raw -LiteralPath (Join-Path $web 'assets/common.js')
}

Describe 'pool-control tables: sortable headers and a row counter' {

    It 'finds one table per page to check' {
        Assert-Equal -Expected 4 -Actual $script:tables.Count 'the page list did not load'
        $findings = @()
        foreach ($t in $script:tables) {
            if ($t.Heads.Count -ne 1) { $findings += "$($t.Page): $($t.Heads.Count) <thead> blocks, expected exactly 1" }
        }
        Assert-NoFinding $findings 'the checks below assume one table per page'
    }

    It 'opens every table with the counter column' {
        $findings = @()
        foreach ($t in $script:tables) {
            $first = [regex]::Match($t.Heads[0], '(?s)<th\b[^>]*>')
            if (-not $first.Success) { $findings += "$($t.Page): no header cells at all"; continue }
            if ($first.Value -notmatch 'class="rownum"') {
                $findings += "$($t.Page): the first header is not the counter column -- $($first.Value.Trim())"
            }
        }
        Assert-NoFinding $findings 'every table leads with the counter column'
    }

    It 'leaves the counter column unsortable' {
        # It numbers where a row SITS, so an order for it would mean nothing --
        # and the page renumbers 1..n on every sort, which a sort of its own
        # would silently undo.
        $findings = @()
        foreach ($t in $script:tables) {
            foreach ($m in [regex]::Matches($t.Heads[0], '(?s)<th\b[^>]*class="rownum"[^>]*>(.*?)</th>')) {
                if ($m.Value -match 'data-sort' -or $m.Groups[1].Value -match '<button') {
                    $findings += "$($t.Page): the counter column carries a sort control"
                }
            }
        }
        Assert-NoFinding $findings 'the counter column is furniture, not data'
    }

    It 'gives every sortable header a real button' {
        # A click handler on the <th> alone reaches neither the keyboard nor a
        # screen reader; the button is what both act on.
        $findings = @()
        foreach ($t in $script:tables) {
            foreach ($m in [regex]::Matches($t.Heads[0], '(?s)<th\b[^>]*data-sort="([^"]+)"[^>]*>(.*?)</th>')) {
                if ($m.Groups[2].Value -notmatch '<button[^>]*class="sort"') {
                    $findings += "$($t.Page): header '$($m.Groups[1].Value)' sorts without a <button class=""sort"">"
                }
            }
        }
        Assert-NoFinding $findings 'a sortable header is a button, not a bare cell'
    }

    It 'marks exactly one column as the order the table opens in' {
        # aria-sort is what announces the order and what draws the arrow. None
        # leaves the opening order unstated; two claim the table is sorted twice.
        $findings = @()
        foreach ($t in $script:tables) {
            $marked = [regex]::Matches($t.Heads[0], 'aria-sort="([^"]+)"')
            if ($marked.Count -ne 1) { $findings += "$($t.Page): $($marked.Count) columns carry aria-sort, expected 1" }
            elseif ($marked[0].Groups[1].Value -ne 'ascending') {
                $findings += "$($t.Page): opens $($marked[0].Groups[1].Value), expected ascending"
            }
        }
        Assert-NoFinding $findings 'every table opens on a stated column, ascending'
    }

    It 'backs every sort key with a value the row builder publishes' {
        # The key is the whole join between the header and the row: a header
        # naming one the builder never sets reads every row as blank, which
        # looks exactly like a table that refuses to sort.
        $findings = @()
        foreach ($t in $script:tables) {
            foreach ($m in [regex]::Matches($t.Heads[0], 'data-sort="([^"]+)"')) {
                $key = $m.Groups[1].Value
                if ($t.Script -notmatch "(?m)\b$([regex]::Escape($key))\b") {
                    $findings += "$($t.Page): header sorts on '$key', which its script never mentions"
                }
            }
        }
        Assert-NoFinding $findings 'a sort key with no value behind it sorts nothing'
    }

    It 'spans the whole table with every empty-state row' {
        # "No pools yet." rides a colspan written as a literal, so a new column
        # leaves it short and the message sits under part of the table.
        $findings = @()
        foreach ($t in $script:tables) {
            $columns = [regex]::Matches($t.Heads[0], '<th\b').Count
            foreach ($m in [regex]::Matches($t.Script, "colspan:\s*'(\d+)'")) {
                if ([int]$m.Groups[1].Value -ne $columns) {
                    $findings += "$($t.Page): a row spans $($m.Groups[1].Value) of $columns columns"
                }
            }
        }
        Assert-NoFinding $findings 'an empty-state row spans every column'
    }

    It 'keeps the shared table helpers the pages are built on' {
        Assert-True ($script:common -match 'Y\.numCell\s*=') 'common.js no longer defines Y.numCell'
        Assert-True ($script:common -match 'Y\.sortTable\s*=') 'common.js no longer defines Y.sortTable'
        $findings = @()
        foreach ($t in $script:tables | Where-Object { $_.Page -ne 'Hosts' }) {
            if ($t.Script -notmatch 'Y\.sortTable\(') { $findings += "$($t.Page): its script never builds a sorter" }
        }
        # Hosts sorts on values two endpoints feed, so it keeps its own
        # comparator and numbers its rows as it renders them.
        $hosts = $script:tables | Where-Object { $_.Page -eq 'Hosts' }
        if ($hosts.Script -notmatch 'Y\.numCell\(') { $findings += 'Hosts: its script never numbers a row' }
        Assert-NoFinding $findings 'the pages and the shared helpers have drifted apart'
    }
}
