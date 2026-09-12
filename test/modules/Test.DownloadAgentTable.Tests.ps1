<#PSScriptInfo
.VERSION 2026.09.12
.GUID 4218aa1e-40ef-4c05-ae43-e48a889c70d1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test download agent table sort counter column pester
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
    Guards the Download pool table of the download-agent UI: the counter column,
    the headers that sort it, and the cell count the totals row has to reach.
.DESCRIPTION
    The page is a static <thead> in index.html paired with the scripts that
    build everything under it -- the SDK's shared runtime (Y.numCell), sort.js
    (the columns a header may sort on) and images.js (the rows and the totals).
    The halves agree on facts no runtime error reports:

      - a header sorts on a KEY, and the comparator has to know that key -- one
        it does not know sorts nothing, which looks like a table that refuses
        to sort;
      - the counter column leads the table and is not itself sortable, since it
        numbers positions on screen rather than anything in the row, and the
        page renumbers 1..n on every sort;
      - the totals row in tfoot spans its columns through a colspan written as
        a literal, which a new column silently leaves short -- and then every
        figure in it sits under the wrong heading.

    The page is served by //go:embed out of the daemon, so nothing here runs the
    service: these are the source files it would embed. The counter column comes
    from two places, and only one of them is shared: its helper is inherited
    from the SDK runtime every page loads first, while its CSS rule still lives
    in this service's own stylesheet, because //go:embed cannot reach outside a
    module and no stylesheet is shared today. Re-adding the helper here would
    override the shared one silently, so the check reads the runtime and this
    service's layer together -- the way the browser does.

    Throw-based Assert-* helpers and every fixture are built in BeforeAll, the
    only scope an It can read: Pester 5 runs file scope and Describe bodies
    during discovery, and nothing they define survives into the run phase.
    Run: pwsh -File test/modules/Test.DownloadAgentTable.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent (Split-Path -Parent $here)
$web = Join-Path $repo 'test/extension/download-agent-service/server/internal/httpsrv/web'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:html = Get-Content -Raw -LiteralPath (Join-Path $web 'index.html')
# The scripts a page of this service runs, in load order: the SDK's shared
# runtime (which holds the table furniture every service UI draws with) and then
# this service's own layer. Read as one, because that is what the browser has.
$script:common = (Get-Content -Raw -LiteralPath (Join-Path $repo 'test/extension/extension-sdk/webui/assets/yuruna.core.js')) +
    "`n" + (Get-Content -Raw -LiteralPath (Join-Path $web 'assets/common.js'))
$script:sortJs = Get-Content -Raw -LiteralPath (Join-Path $web 'assets/sort.js')
$script:images = Get-Content -Raw -LiteralPath (Join-Path $web 'assets/images.js')
$script:style = Get-Content -Raw -LiteralPath (Join-Path $web 'assets/style.css')

$heads = [regex]::Matches($script:html, '(?s)<thead>(.*?)</thead>')
$script:head = if ($heads.Count -eq 1) { $heads[0].Groups[1].Value } else { '' }
$script:headCount = $heads.Count
$script:columns = [regex]::Matches($script:head, '<th\b').Count

# The two builders, isolated from the script so a cell counted below belongs to
# the row it is claimed for. Each runs from its `function <name>(` to the first
# line that closes it at column 0.
function Get-JsFunction {
    param([string]$Source, [string]$Name)
    $m = [regex]::Match($Source, "(?sm)^  function $([regex]::Escape($Name))\(.*?^  \}")
    if (-not $m.Success) { throw "images.js no longer defines $Name()" }
    return $m.Value
}
$script:rowEl = Get-JsFunction -Source $script:images -Name 'rowEl'
$script:totals = Get-JsFunction -Source $script:images -Name 'renderTotals'

# Cells a builder emits, counting a colspan as the columns it covers. A row's
# identifying cell is a <th scope="row"> rather than a <td> -- it names the row
# so a screen reader announces the image key alongside every other cell,
# including the three action buttons that would otherwise be "Delete" repeated
# down the table -- and it still occupies a column, so it counts here.
function Measure-ColumnSpan {
    param([string]$Body)
    $n = [regex]::Matches($Body, "Y\.el\('td'").Count +
         [regex]::Matches($Body, "Y\.el\('th'").Count +
         [regex]::Matches($Body, 'Y\.numCell\(').Count
    foreach ($m in [regex]::Matches($Body, "colspan:\s*'(\d+)'")) { $n += [int]$m.Groups[1].Value - 1 }
    return $n
}
}

Describe 'download-agent Download pool table: sortable headers and a row counter' {

    It 'finds one table to check' {
        Assert-Equal -Expected 1 -Actual $script:headCount 'the checks below assume one table on the page'
        Assert-True ($script:columns -gt 1) 'the table has no header cells at all'
    }

    It 'opens the table with the counter column' {
        $first = [regex]::Match($script:head, '(?s)<th\b[^>]*>')
        Assert-True $first.Success 'no header cells at all'
        Assert-True ($first.Value -match 'class="rownum"') `
            "the first header is not the counter column -- $($first.Value.Trim())"
        Assert-True ($first.Value -match 'aria-label="Row number"') `
            'the counter header reads as "#" alone to a screen reader'
    }

    It 'leaves the counter column unsortable' {
        # It numbers where a row SITS, so an order for it would mean nothing --
        # and the page renumbers 1..n on every sort, which a sort of its own
        # would silently undo.
        $findings = @()
        foreach ($m in [regex]::Matches($script:head, '(?s)<th\b[^>]*class="rownum"[^>]*>(.*?)</th>')) {
            if ($m.Value -match 'data-sort' -or $m.Groups[1].Value -match '<button') {
                $findings += 'the counter column carries a sort control'
            }
        }
        Assert-NoFinding $findings 'the counter column is furniture, not data'
    }

    It 'gives every sortable header a real button' {
        # A click handler on the <th> alone reaches neither the keyboard nor a
        # screen reader; the button is what both act on.
        $findings = @()
        foreach ($m in [regex]::Matches($script:head, '(?s)<th\b[^>]*data-sort="([^"]+)"[^>]*>(.*?)</th>')) {
            if ($m.Groups[2].Value -notmatch '<button[^>]*class="th-sort"') {
                $findings += "header '$($m.Groups[1].Value)' sorts without a <button class=""th-sort"">"
            }
        }
        Assert-NoFinding $findings 'a sortable header is a button, not a bare cell'
    }

    It 'backs every sort key with a column the comparator knows' {
        # The key is the whole join between the header and sort.js: a header
        # naming one S.columns does not list is refused by S.isColumn and sorts
        # nothing at all, which looks exactly like a table that will not sort.
        $m = [regex]::Match($script:sortJs, "S\.columns\s*=\s*\[(.*?)\]")
        Assert-True $m.Success 'sort.js no longer declares S.columns'
        $known = [regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        $findings = @()
        foreach ($h in [regex]::Matches($script:head, 'data-sort="([^"]+)"')) {
            $key = $h.Groups[1].Value
            if ($known -notcontains $key) { $findings += "header sorts on '$key', which sort.js does not list" }
        }
        Assert-NoFinding $findings 'a sort key the comparator does not know sorts nothing'
    }

    It 'numbers the rows by where they sit, not by what is in them' {
        # The counter is rebuilt from the painted order, so it reads 1..n down
        # the page whatever column the operator sorted by.
        Assert-True ($script:rowEl -match 'Y\.numCell\(') 'the row builder no longer emits a counter cell'
        # The counter comes from the loop index, not from the row: matching only
        # `i + 1` as the second argument leaves the first one free, so renaming
        # the row variable does not read as the numbering having changed.
        Assert-True ($script:images -match 'rowEl\([^,()]+,\s*i \+ 1\)') `
            'the rows are no longer numbered from their position in the sorted order'
    }

    It 'fills every column of the table with each row it builds' {
        Assert-Equal -Expected $script:columns -Actual (Measure-ColumnSpan $script:rowEl) `
            'a data row and the header have drifted apart'
    }

    It 'spans the whole table with the totals row' {
        # The totals row rides a colspan written as a literal, so a new column
        # leaves it short and every figure lands under the wrong heading.
        Assert-Equal -Expected $script:columns -Actual (Measure-ColumnSpan $script:totals) `
            'the totals row does not reach the last column'
    }

    It 'keeps the counter column the shared runtime defines' {
        # The helper is inherited: it lives once in the SDK runtime every page
        # loads before its own scripts. Its CSS rule is not -- //go:embed cannot
        # reach outside its module and no stylesheet is shared today, so each
        # daemon still ships this rule in its own sheet and it has to stay there.
        Assert-True ($script:common -match 'Y\.numCell\s*=') 'the runtime no longer defines Y.numCell'
        Assert-True ($script:style -match '(?m)^th\.rownum,\s*td\.rownum\s*\{') `
            'style.css no longer styles the counter column'
    }
}
