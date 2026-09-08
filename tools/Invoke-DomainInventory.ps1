<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42d0a94f-27b6-4c85-9e13-8a604fb2d7c1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization inventory domains measurement
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Count what is left to translate, per domain, across both repositories.
.DESCRIPTION
    Every estimate for this work so far has been a guess about a number nobody
    had. This produces the number: how many operator-facing strings each domain
    holds, where they are, and which of them already come from a catalog.

    The counting is deliberately conservative and its rules are stated rather
    than tuned. A candidate is a quoted literal that reads like a sentence to a
    person: it has a space, it has letters, and it is not one of the shapes that
    are obviously not prose -- a path, a url, a format specifier, a code, a
    single word. Being conservative in that direction matters more than being
    exhaustive: an over-count turns the reforecast into fiction, and a slight
    under-count still tells an owner what they are taking on.

    This does not decide what should be translated. A string being here means
    somebody has to look at it, which is the useful thing to know before
    committing to a schedule.

    Both repositories are walked when the sibling is present. A domain that
    lives in yuruna-project is somebody else's release cadence, and the count
    is what tells you whether that matters.
.PARAMETER Update
    Write globalization/manifests/domain-inventory.json instead of reporting.
.PARAMETER Check
    Fail unless the recorded inventory is byte-for-byte current. Release gates
    use this against the private-stripped paired trees.
.PARAMETER ProjectRoot
    Project checkout paired with this framework tree. Defaults to the sibling
    yuruna-project; the publisher supplies its private-stripped candidate.
.PARAMETER Root
    Framework candidate root. Defaults to this tool's repository. The override
    is used by isolated pre-commit discovery tests.
.PARAMETER OutputPath
    Inventory file to write or compare. Defaults to the checked manifest. The
    override is used by mutation tests to prove a missing row fails.
.PARAMETER Quiet
    Print only the totals.
.EXAMPLE
    pwsh -File tools/Invoke-DomainInventory.ps1
.EXAMPLE
    pwsh -File tools/Invoke-DomainInventory.ps1 -Update
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Update,
    [switch]$Check,
    [switch]$Quiet,
    [string]$ProjectRoot,
    [string]$OutputPath,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
$RepoRoot = if ($Root) { [IO.Path]::GetFullPath($Root) } else { Split-Path -Parent $PSScriptRoot }
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna-project' }
if (-not $OutputPath) { $OutputPath = Join-Path $RepoRoot 'globalization/manifests/domain-inventory.json' }

$ProjectSourceDocuments = @(
    'README.md'
    'template/README.md'
    'example/README.md'
    'example/website/README.md'
    'example/text-to-sql/README.md'
)
$ProjectTranslatedDocuments = @(
    'docs/pt-BR/README.md'
    'docs/pt-BR/template/README.md'
    'docs/pt-BR/example/README.md'
    'docs/pt-BR/example/website/README.md'
    'docs/pt-BR/example/text-to-sql/README.md'
)

# A domain is a surface with one owner and one conversion lane. The order is
# the order the plan converts them in, so the report reads as a queue.
$Domains = @(
    @{ Name = 'status-ui';        Repo = 'yuruna'; Paths = @('test/status') }
    @{ Name = 'status-service';   Repo = 'yuruna'; Paths = @('test/service') }
    @{ Name = 'pool-control';     Repo = 'yuruna'; Paths = @('test/extension/pool-control-service') }
    @{ Name = 'stash';            Repo = 'yuruna'; Paths = @('test/extension/stash-service') }
    @{ Name = 'download-agent';   Repo = 'yuruna'; Paths = @('test/extension/download-agent-service') }
    @{ Name = 'caching-proxy';    Repo = 'yuruna'; Paths = @('test/extension/caching-proxy-service', 'test/extension/caching-proxy-parser-service') }
    @{ Name = 'pool-aggregator';  Repo = 'yuruna'; Paths = @('test/extension/pool-aggregator-service') }
    @{ Name = 'extension-sdk';    Repo = 'yuruna'; Paths = @('test/extension/extension-sdk') }
    @{ Name = 'notification';     Repo = 'yuruna'; Paths = @('test/extension/notification') }
    @{ Name = 'runner';           Repo = 'yuruna'; Paths = @('test/modules') }
    @{ Name = 'host-drivers';     Repo = 'yuruna'; Paths = @('host') }
    @{ Name = 'automation';       Repo = 'yuruna'; Paths = @('automation') }
    @{ Name = 'guest-bringup';    Repo = 'yuruna'; Paths = @('guest', 'install') }
    @{ Name = 'documentation';    Repo = 'yuruna'; Paths = @('docs') }
    @{ Name = 'project-config';   Repo = 'yuruna-project'; Paths = @('template', 'example', 'test') }
    @{ Name = 'project-docs';     Repo = 'yuruna-project'; Paths = @('docs', 'book') }
)

# Shapes that are never prose. Checked before the prose test, because the cheap
# exclusion is what keeps the count honest.
$NotProse = @(
    '^\s*$'                          # empty
    '^[^ ]+$'                        # a single token: a name, a key, a path
    '^https?://'                     # a url
    '^[\\/~.]'                       # a path
    '^[A-Za-z]:[\\/]'                # a Windows path
    '^\{\d'                          # a format specifier
    '^-{2,}'                         # a rule or a flag
    '^\s*#'                          # a comment fragment
    '^[a-z0-9_.]+$'                  # a code or an identifier
    '^\d[\d\s.,:+-]*$'               # a number or a timestamp
    '^[%&|<>=!*/+\\^$@#]'            # an operator or a pattern
)

function Test-IsProseCandidate {
    <#
    .SYNOPSIS
        Whether a literal reads like something a person is meant to understand.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $t = $Text.Trim()
    if ($t.Length -lt 8) { return $false }
    if ($t.Length -gt 400) { return $false }
    foreach ($pattern in $NotProse) { if ($t -match $pattern) { return $false } }
    # Two words and a letter majority: prose has spaces between words and is
    # mostly letters, which separates it from a serialized structure that
    # happens to contain a space.
    if (($t -split '\s+').Count -lt 3) { return $false }
    $letters = ([regex]::Matches($t, '[A-Za-z]')).Count
    if ($letters -lt ($t.Length / 2)) { return $false }
    return $true
}

# Extracting the literals.
#
# A regex over quotes is not good enough to publish a number from. Scanning for
# '...' and "..." independently desynchronizes on the first apostrophe inside a
# comment or a double-quoted string, and from there every gap BETWEEN two
# literals matches as though it were one. The first version of this counted
# fragments like ", { text: what + " as operator-facing prose, which would have
# put a few hundred phantom strings into a schedule.
#
# PowerShell has a parser, so its literals are taken exactly. The other two
# languages get a single left-to-right scan that knows which quote opened the
# string it is inside, which is what makes a stray apostrophe harmless.

function Get-PowerShellStringLiteral {
    <#
    .SYNOPSIS
        Every string literal in a PowerShell file, from the parser.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
    $out = [Collections.Generic.List[string]]::new()
    foreach ($t in @($tokens)) {
        if ($t.Kind -eq 'StringLiteral' -or $t.Kind -eq 'StringExpandable') {
            if ($null -ne $t.Value) { $out.Add([string]$t.Value) }
        }
    }
    return $out.ToArray()
}

function Get-ScannedStringLiteral {
    <#
    .SYNOPSIS
        Every quoted literal in a C-like source, by a scan that tracks its own
        state.
    .DESCRIPTION
        One pass, left to right. Inside a string only the matching quote closes
        it, and a backslash escapes the next character, so an apostrophe in a
        double-quoted string -- or in a comment -- cannot shift everything after
        it by one literal. Line comments are skipped for the same reason.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Text, [switch]$BacktickRaw)

    $out = [Collections.Generic.List[string]]::new()
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '*') {
            $i += 2
            while (($i + 1) -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
            $i += 2
            continue
        }
        if ($c -eq '"' -or $c -eq "'" -or ($BacktickRaw -and $c -eq '`')) {
            $quote = $c
            $i++
            $sb = [Text.StringBuilder]::new()
            while ($i -lt $n -and $Text[$i] -ne $quote) {
                if ($Text[$i] -eq '\' -and $quote -ne '`' -and ($i + 1) -lt $n) { $i += 2; [void]$sb.Append(' '); continue }
                [void]$sb.Append($Text[$i])
                $i++
            }
            $i++
            $out.Add($sb.ToString())
            continue
        }
        $i++
    }
    return $out.ToArray()
}

function Test-IsSentenceFragment {
    <#
    .SYNOPSIS
        Whether a candidate is a piece of a sentence rather than a sentence.
    .DESCRIPTION
        A string that opens or closes mid-phrase is being concatenated with a
        value at run time -- "A sweep of ", " runs on its own every ". Those
        cost more than a whole message to convert and are the reason a
        conversion estimate built on a raw count is wrong: the sentence has to
        be recomposed before it can be translated at all, because word order is
        not the same in every language and a fragment cannot be reordered.

        Counting them separately is what turns one number into two: how many
        strings there are, and how many of them are structural work.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    # Only signals that actually distinguish a fragment from a short label.
    #
    # An earlier rule also called anything ending in a lower-case word a
    # fragment, which made "Pause after step" -- a button label, and a complete
    # unit -- structural work. Whole categories of label end that way, so that
    # rule inflated the count with the very strings that need no recomposition
    # at all.
    #
    # What a concatenated piece actually looks like: it carries the whitespace
    # that would otherwise have to live in the caller, or it ends on a connector
    # that is plainly waiting for a value.
    if ($Text -ne $Text.TrimStart()) { return $true }   # opens mid-phrase
    if ($Text -ne $Text.TrimEnd()) { return $true }     # closes mid-phrase
    $t = $Text.Trim()
    if (-not $t) { return $false }
    if ($t -cmatch '[:,;]$') { return $true }           # a value follows
    return $false
}

function Test-IsReachableProjectYaml {
    <#
    .SYNOPSIS
        Whether the framework reads this project's operator display metadata.
    .DESCRIPTION
        Project product code, Helm charts, book fixtures, and the nested-host
        worked example are deliberate exclusions.  The sequence planner reads
        the root test-set map and the runnable example test definitions; those
        are the YAML labels an operator actually sees.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $p = $Path -replace '\\', '/'
    if ($p -eq 'test/test.runner.yml' -or $p -eq 'test/test.runner.yaml') { return $true }
    if ($p -match '^template/(config|test)/.+\.ya?ml$') { return $true }
    if ($p -match '^example/[^/]+/(config|test)/.+\.ya?ml$' -and
        $p -notmatch '^example/nested\.host/') { return $true }
    return $false
}

function Get-YamlDisplayField {
    <#
    .SYNOPSIS
        Walk a parsed YAML object and return reachable display fields.
    .DESCRIPTION
        This consumes ConvertFrom-Yaml output rather than matching source text.
        A quoted colon, folded scalar, comment, or reordered map therefore
        cannot create or hide a field.  Container rows and localized values are
        separate so the inventory can distinguish one map to convert from the
        translations already present inside it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [string]$ObjectPath = '$'
    )

    $found = [Collections.Generic.List[object]]::new()
    if ($null -eq $Value) { return $found.ToArray() }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($keyValue in $Value.Keys) {
            $key = [string]$keyValue
            $child = $Value[$keyValue]
            $path = "$ObjectPath.$key"
            if ($key -in @('displayName', 'description')) {
                $found.Add([pscustomobject]@{
                        path = $path; kind = 'english-scalar'; key = $key
                        locale = ''; value = if ($null -eq $child) { '' } else { [string]$child }
                    })
            } elseif ($key -in @('displayNameLocalized', 'descriptionLocalized')) {
                $found.Add([pscustomobject]@{
                        path = $path; kind = 'localized-map'; key = $key
                        locale = ''; value = ''
                    })
                if ($child -is [Collections.IDictionary]) {
                    foreach ($localeKey in $child.Keys) {
                        $found.Add([pscustomobject]@{
                                path = "$path.$localeKey"; kind = 'localized-value'; key = $key
                                locale = [string]$localeKey
                                value = if ($null -eq $child[$localeKey]) { '' } else { [string]$child[$localeKey] }
                            })
                    }
                }
            }
            foreach ($row in @(Get-YamlDisplayField -Value $child -ObjectPath $path)) { $found.Add($row) }
        }
    } elseif ($Value -is [Collections.IList] -and $Value -isnot [string]) {
        for ($i = 0; $i -lt $Value.Count; $i++) {
            foreach ($row in @(Get-YamlDisplayField -Value $Value[$i] -ObjectPath "$ObjectPath[$i]")) { $found.Add($row) }
        }
    }
    return $found.ToArray()
}

function Get-ProjectConfigCount {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $result = [ordered]@{
        domain = 'project-config'; repository = 'yuruna-project'
        present = $false; files = 0; candidates = 0; fragments = 0
        catalogCalls = 0; pages = 0; markdown = 0; yamlFields = 0
        englishScalars = 0; localizedMaps = 0; localizedValues = 0
        inventoryFiles = @(); topFiles = @()
    }
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return $result }
    $result.present = $true

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Import-Module powershell-yaml -ErrorAction Stop -Verbose:$false
    }
    Push-Location $ProjectRoot
    try { $tracked = @(& git ls-files --cached --others --exclude-standard -- '*.yml' '*.yaml') } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "git could not enumerate YAML in $ProjectRoot" }
    $tracked = @($tracked | Sort-Object -Unique)

    $perFile = @{}
    foreach ($relative in @($tracked | Where-Object { Test-IsReachableProjectYaml -Path $_ } | Sort-Object)) {
        $full = Join-Path $ProjectRoot $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "candidate project YAML is missing: $relative" }
        $parsed = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($full)) -Ordered
        $fields = @(Get-YamlDisplayField -Value $parsed)
        # Inventory the whole reachable map, including a currently empty one.
        # Otherwise adding a map before its first display field creates a path
        # the encoding gate can discover but the generator can never record.
        $result.files++
        $result.inventoryFiles += $relative
        $result.yamlFields += @($fields | Where-Object kind -NE 'localized-value').Count
        $result.englishScalars += @($fields | Where-Object kind -EQ 'english-scalar').Count
        $result.localizedMaps += @($fields | Where-Object kind -EQ 'localized-map').Count
        $result.localizedValues += @($fields | Where-Object kind -EQ 'localized-value').Count
        # One English scalar and one translated value are each one unit of
        # wording.  A map container is structure, counted separately above.
        $wording = @($fields | Where-Object kind -IN @('english-scalar', 'localized-value')).Count
        $result.candidates += $wording
        $perFile[$relative] = $wording
    }
    $result.inventoryFiles = @($result.inventoryFiles | Sort-Object)
    $result.topFiles = @($perFile.GetEnumerator() |
        Sort-Object -Property @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key } } |
        Select-Object -First 5 | ForEach-Object { [ordered]@{ file = $_.Key; candidates = $_.Value } })
    return $result
}

function Get-ProjectDocumentCount {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $result = [ordered]@{
        domain = 'project-docs'; repository = 'yuruna-project'
        present = $false; files = 0; candidates = 0; fragments = 0
        catalogCalls = 0; pages = 0; markdown = 0; yamlFields = 0
        sourceDocuments = @($ProjectSourceDocuments)
        translatedDocuments = @($ProjectTranslatedDocuments)
        indexDocuments = @('docs/pt-BR/index.md')
        inventoryFiles = @(); topFiles = @()
    }
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return $result }
    $result.present = $true
    $all = @($result.sourceDocuments) + @($result.translatedDocuments) + @($result.indexDocuments)
    foreach ($relative in $all) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $relative) -PathType Leaf)) {
            throw "required project document is missing: $relative"
        }
    }
    $result.inventoryFiles = @($all)
    $result.markdown = $all.Count
    return $result
}

function Get-DomainCount {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Domain)

    if ($Domain.Name -eq 'project-config') { return Get-ProjectConfigCount }
    if ($Domain.Name -eq 'project-docs') { return Get-ProjectDocumentCount }

    $root = if ($Domain.Repo -eq 'yuruna') { $RepoRoot } else { $ProjectRoot }
    $result = [ordered]@{
        domain        = [string]$Domain.Name
        repository    = [string]$Domain.Repo
        present       = $false
        files         = 0
        candidates    = 0
        fragments     = 0
        catalogCalls  = 0
        pages         = 0
        markdown      = 0
        yamlFields    = 0
        topFiles      = @()
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $result }
    $result.present = $true

    # Tracked and untracked candidate files. Ignored status logs and runtime
    # scratch remain excluded by Git, while a new source file is protected
    # before its first commit.
    Push-Location $root
    try { $tracked = @(& git ls-files --cached --others --exclude-standard) } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "git could not enumerate source in $root" }
    $tracked = @($tracked | Sort-Object -Unique)

    $perFile = @{}
    foreach ($rel in @($Domain.Paths)) {
        $dir = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $inPath = @($tracked | Where-Object { $_ -eq $rel -or $_.StartsWith("$rel/") })
        foreach ($relative in $inPath) {
            $full = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $file = [IO.FileInfo]::new($full)
            $ext = $file.Extension.ToLowerInvariant()
            $name = $file.Name
            # Tests describe behavior to a developer, not a state to an
            # operator. Counting them would inflate every domain by its own
            # test suite and tell an owner nothing about their conversion.
            if ($name -match '(\.Tests\.ps1|_test\.go|\.test\.js)$') { continue }
            if ($ext -eq '.md') { $result.markdown++; continue }
            if ($ext -eq '.html') { $result.pages++ }
            if ($ext -notin '.ps1', '.psm1', '.js', '.go') { continue }

            $text = [IO.File]::ReadAllText($full)
            $result.files++
            foreach ($m in [regex]::Matches($text, 'YurunaI18n\.t\(|Yuruna\.t\(|Format-CatalogMessage|catalog\.Render|Translate\(')) {
                $result.catalogCalls++
            }
            $literals = if ($ext -in '.ps1', '.psm1') {
                Get-PowerShellStringLiteral -Path $full
            } else {
                Get-ScannedStringLiteral -Text $text -BacktickRaw:($ext -eq '.go')
            }
            $found = 0
            foreach ($literal in $literals) {
                if (-not (Test-IsProseCandidate -Text $literal)) { continue }
                $found++
                if (Test-IsSentenceFragment -Text $literal) { $result.fragments++ }
            }
            if ($found -gt 0) {
                $result.candidates += $found
                $perFile[$relative] = $found
            }
        }
    }
    # The handful of files an owner should open first. A domain's work is
    # rarely spread evenly, and naming the heaviest few is more actionable than
    # a total on its own.
    $result.topFiles = @(
        $perFile.GetEnumerator() | Sort-Object -Property @{ Expression = { $_.Value }; Descending = $true },
                                                          @{ Expression = { $_.Key } } |
            Select-Object -First 5 | ForEach-Object { [ordered]@{ file = $_.Key; candidates = $_.Value } })
    return $result
}

$rows = @(foreach ($d in $Domains) { Get-DomainCount -Domain $d })

$doc = [ordered]@{
    schema      = 'yuruna.domain-inventory/v2'
    note        = 'Counts of operator-facing wording per domain. Source-code candidates come from language-aware literal extraction; project display metadata comes from parsed reachable YAML. Tests are excluded except project test definitions whose descriptions are shipped operator UI data.'
    repositories = [ordered]@{
        yuruna        = $true
        'yuruna-project' = (Test-Path -LiteralPath $ProjectRoot -PathType Container)
    }
    totals = [ordered]@{
        domains      = @($rows | Where-Object { $_.present }).Count
        # Summed by hand: Measure-Object reads a PROPERTY, and these rows are
        # ordered dictionaries whose entries are keys rather than properties,
        # so it silently sums nothing and reports a blank.
        files        = [int](@($rows | ForEach-Object { [int]$_.files } | Measure-Object -Sum).Sum)
        candidates   = [int](@($rows | ForEach-Object { [int]$_.candidates } | Measure-Object -Sum).Sum)
        fragments    = [int](@($rows | ForEach-Object { [int]$_.fragments } | Measure-Object -Sum).Sum)
        catalogCalls = [int](@($rows | ForEach-Object { [int]$_.catalogCalls } | Measure-Object -Sum).Sum)
        pages        = [int](@($rows | ForEach-Object { [int]$_.pages } | Measure-Object -Sum).Sum)
        markdown     = [int](@($rows | ForEach-Object { [int]$_.markdown } | Measure-Object -Sum).Sum)
        yamlFields   = [int](@($rows | ForEach-Object { [int]$_.yamlFields } | Measure-Object -Sum).Sum)
    }
    projectScope = [ordered]@{
        yamlIncludes = @(
            'test/test.runner.ya?ml'
            'template/{config,test}/**/*.ya?ml'
            'example/<product>/{config,test}/**/*.ya?ml'
        )
        excluded = @(
            [ordered]@{ path = 'book/**'; reason = 'documentation fixtures, not a runnable project surface' }
            [ordered]@{ path = 'example/nested.host/**'; reason = 'worked self-hosting example excluded from the release display contract' }
            [ordered]@{ path = 'example/*/workloads/**'; reason = 'Helm and product deployment metadata belongs to the example application' }
            [ordered]@{ path = 'example/*/components/**'; reason = 'example application implementation is product content, not framework UI' }
        )
        sourceDocuments = @($ProjectSourceDocuments)
        translatedDocuments = @($ProjectTranslatedDocuments)
    }
    domains = @($rows)
}

$json = ((ConvertTo-Json -InputObject $doc -Depth 8) -replace "`r`n", "`n").TrimEnd() + "`n"

if ($Update) {
    if ($PSCmdlet.ShouldProcess($OutputPath, 'record the domain inventory')) {
        [IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
        if (-not $Quiet) { Write-Output "inventory written: $OutputPath" }
    }
    exit 0
}

if ($Check) {
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        Write-Output "FINDING: no recorded inventory at $OutputPath"
        exit 1
    }
    $recorded = ([IO.File]::ReadAllText($OutputPath) -replace "`r`n", "`n")
    if ($recorded -cne $json) {
        Write-Output 'FINDING: the recorded domain inventory does not match these repository trees; run tools/Invoke-DomainInventory.ps1 -Update.'
        # Say what moved. This gate closes the seed and engineering markers, and
        # a bare "run -Update" makes an ordinary edit indistinguishable from a
        # regression: the only way to see the difference is to regenerate to a
        # scratch path and diff by hand, which is the work this line exists to
        # save.
        $was = $null
        try { $was = ConvertFrom-Json -InputObject $recorded } catch { $was = $null }
        if ($was) {
            $now = ConvertFrom-Json -InputObject $json
            $counters = @('files', 'candidates', 'fragments', 'catalogCalls', 'pages', 'markdown', 'yamlFields')
            foreach ($counter in @('domains') + $counters) {
                $before = [int]$was.totals.$counter
                $after = [int]$now.totals.$counter
                if ($before -ne $after) { Write-Output "  totals.${counter}: $before -> $after" }
            }
            $wasDomain = @{}
            foreach ($d in @($was.domains)) { $wasDomain[[string]$d.domain] = $d }
            foreach ($d in @($now.domains)) {
                $name = [string]$d.domain
                if (-not $wasDomain.ContainsKey($name)) { Write-Output "  domain added: $name"; continue }
                $changed = @($counters | Where-Object { [int]$wasDomain[$name].$_ -ne [int]$d.$_ } |
                    ForEach-Object { "$_ $([int]$wasDomain[$name].$_) -> $([int]$d.$_)" })
                if ($changed.Count -gt 0) { Write-Output "  ${name}: $($changed -join ', ')" }
            }
            foreach ($name in @($wasDomain.Keys | Sort-Object)) {
                if (-not @($now.domains | Where-Object { [string]$_.domain -eq $name })) {
                    Write-Output "  domain removed: $name"
                }
            }
        }
        exit 1
    }
    if (-not $Quiet) { Write-Output "Invoke-DomainInventory: recorded inventory is current at $OutputPath" }
    exit 0
}

if (-not $Quiet) {
    Write-Output ("{0,-18} {1,-16} {2,7} {3,11} {4,10} {5,8}" -f 'DOMAIN', 'REPOSITORY', 'FILES', 'CANDIDATES', 'FRAGMENTS', 'CATALOG')
    foreach ($r in $rows) {
        if (-not $r.present) {
            Write-Output ("{0,-18} {1,-16} {2,7} {3,11} {4,10} {5,8}" -f $r.domain, $r.repository, '--', '--', '--', '--')
            continue
        }
        Write-Output ("{0,-18} {1,-16} {2,7} {3,11} {4,10} {5,8}" -f $r.domain, $r.repository, $r.files, $r.candidates, $r.fragments, $r.catalogCalls)
    }
}
Write-Output ("Invoke-DomainInventory: {0} domain(s), {1} candidate(s) across {2} file(s); {3} are sentence fragments needing recomposition; {4} already render from a catalog." -f
    $doc.totals.domains, $doc.totals.candidates, $doc.totals.files, $doc.totals.fragments, $doc.totals.catalogCalls)
exit 0
