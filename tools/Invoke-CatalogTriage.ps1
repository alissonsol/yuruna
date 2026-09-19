<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4284df2f-52a5-4145-9114-1e901d60121e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization triage catalog candidates classification
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
    Give every candidate literal a disposition: convert, internal, or
    unexplained.
.DESCRIPTION
    The domain inventory answers "how many quoted literals read like prose".
    That number is a scanner's guess, and two thirds of it is PowerShell inside
    the runner and the host drivers -- log lines, diagnostics, identifiers and
    regular-expression bodies that must never become shipped messages. A count
    nobody can act on does not move, so this assigns each candidate one of three
    dispositions and records the ones that still need a person.

        convert      operator-facing text that belongs in a message catalog
        internal     not shipped UI; carries the rule that decided it
        unexplained  the classifier is not confident -- a person decides

    Only `unexplained` is a number to drive to zero. It shrinks by a person
    running this again with an explicit decision, which is recorded and from
    then on outranks the classifier. The classifier never overrules a recorded
    decision, and it never promotes on a hunch: a wrong `internal` leaves a
    sentence untranslated, while a wrong `convert` puts a stack frame or a
    regular expression in front of a reader. So anything without a positive
    signal stays unexplained rather than being guessed into a catalog.

    The unit of triage is a distinct literal within one domain, not one
    occurrence. The same log sentence repeated across forty files is one
    decision, and the report carries both numbers so it reconciles with the
    inventory.

    Literal extraction is not re-implemented here. The prose test, the shape
    exclusions and the comment-aware scanner are lifted out of
    Invoke-DomainInventory.ps1 at startup, so a candidate set that drifts from
    the inventory is impossible by construction. Classification needs source
    positions that those helpers do not return, so PowerShell literals are read
    from the parser's own tokens -- the same token kinds the inventory selects --
    and the scanned languages are located by walking forward through the text.

    Rewriting call sites is out of scope. This decides what each literal IS; a
    per-domain conversion step changes the code under its own tests.

    Exit codes:
        0  classification succeeded and nothing is unexplained
        1  unexplained candidates remain (-Check), or a write failed
        2  the invocation or the environment is unusable
.PARAMETER Check
    Classify and report without writing. The default when neither -Check nor
    -Update is given. Exits 1 while any candidate is unexplained, which is what
    makes it usable as a gate.
.PARAMETER Update
    Write globalization/manifests/candidate-triage.json. Additive: recorded
    decisions and previously emitted messages are carried forward untouched.
.PARAMETER Domain
    Triage one domain instead of all of them. Because a manifest scoped to one
    domain would silently narrow the gate for every other domain, combining
    this with -Update requires an explicit -OutputPath.
.PARAMETER Decide
    Candidate id (as printed for an unexplained candidate, or recorded in the
    manifest) to resolve by hand. Repeatable. Requires -Update, -As and
    -Reason.
.PARAMETER As
    The disposition a -Decide id is being given: convert or internal.
.PARAMETER Reason
    Why the -Decide ids take that disposition. Recorded beside the decision,
    because a bare verdict is unreviewable six months later.
.PARAMETER EmitCatalog
    Also merge the proposed messages for `convert` candidates into the source
    catalogs under -CatalogRoot. Additive only: an existing key is never
    rewritten or removed. Off by default, so an ordinary -Update never touches
    a shipped catalog.
.PARAMETER CatalogRoot
    Source catalog directory -EmitCatalog merges into. Defaults to the en-US
    source catalogs.
.PARAMETER Root
    Framework repository root. Defaults to this tool's repository.
.PARAMETER OutputPath
    Triage manifest to write or read. Defaults to the checked manifest.
.PARAMETER Quiet
    Print only the summary.
.EXAMPLE
    pwsh -File tools/Invoke-CatalogTriage.ps1
    Reports the per-domain triage and fails while anything is unexplained.
.EXAMPLE
    pwsh -File tools/Invoke-CatalogTriage.ps1 -Update
    Records the triage manifest.
.EXAMPLE
    pwsh -File tools/Invoke-CatalogTriage.ps1 -Update -Decide 3f2a1c0b9d8e7a65 -As internal -Reason 'transcript diagnostic'
    Resolves one candidate by hand; the classifier never reverses it.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([string])]
param(
    [switch]$Check,
    [switch]$Update,
    [string]$Domain,
    [string[]]$Decide,
    [ValidateSet('convert', 'internal')][string]$As,
    [string]$Reason,
    [switch]$EmitCatalog,
    [string]$CatalogRoot,
    [string]$Root,
    [string]$OutputPath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = if ($Root) { [IO.Path]::GetFullPath($Root) } else { Split-Path -Parent $PSScriptRoot }
if (-not $OutputPath) { $OutputPath = Join-Path $RepoRoot 'globalization/manifests/candidate-triage.json' }
if (-not $CatalogRoot) { $CatalogRoot = Join-Path $RepoRoot 'globalization/catalogs/en-US' }
if (-not $Update) { $Check = $true }

# --- REGION: Shared extraction, lifted from the inventory
#
# The inventory's count and this tool's triage have to describe the same set of
# literals, or the number being closed here is not the number being reported
# there. Copying the prose test and the scanner would leave two definitions of
# what a candidate is, agreeing until somebody edits one of them, so the
# definitions are read out of the inventory itself and evaluated in this scope.
# A rename over there fails here loudly, at startup, instead of quietly
# producing a different number.
$InventoryPath = Join-Path $PSScriptRoot 'Invoke-DomainInventory.ps1'
$SharedFunction = @('Test-IsProseCandidate', 'Get-ScannedStringLiteral', 'Test-IsSentenceFragment')
$SharedVariable = @('NotProse', 'Domains')

function Get-OrdinalOrder {
    <#
    .SYNOPSIS
        Strings in ordinal order.
    .DESCRIPTION
        Sort-Object compares by the current culture, which orders punctuation
        and case differently from one machine to the next. The manifest has to
        be byte-identical wherever it is regenerated, so every ordering that
        reaches the file is ordinal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Value)

    $copy = [string[]]@($Value)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

function Get-SharedDefinition {
    <#
    .SYNOPSIS
        The source text of the inventory definitions this tool reuses.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $parseError = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseError)
    if ($parseError) { throw "$Path does not parse: $($parseError[0].Message)" }

    $parts = [Collections.Generic.List[string]]::new()
    foreach ($name in $SharedVariable) {
        $wanted = $name
        $node = @($ast.FindAll({
                    param($n)
                    $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -ceq $wanted
                }, $true)) | Select-Object -First 1
        if (-not $node) { throw "$Path no longer defines `$$name, which the triage classifier reuses" }
        $parts.Add($node.Extent.Text)
    }
    foreach ($name in $SharedFunction) {
        $wanted = $name
        $node = @($ast.FindAll({
                    param($n)
                    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $wanted
                }, $true)) | Select-Object -First 1
        if (-not $node) { throw "$Path no longer defines $name, which the triage classifier reuses" }
        $parts.Add($node.Extent.Text)
    }
    return ($parts -join "`n")
}

# --- REGION: Classification rules
#
# Every rule states, in one sentence, why the text it matches is not shipped UI.
# The reason travels with the verdict into the manifest so a reviewer can
# disagree with a rule rather than with a number.
$InternalReason = [ordered]@{
    'diagnostic-stream'   = 'maintainer-only verbose/debug or browser/service console logging; operator streams are classified separately'
    'bootstrap-english'   = 'declared byte-stream installer or Windows PowerShell bootstrap exclusion; its bytes and machine control flow remain invariant'
    'sql-statement'       = 'SQL query or schema statement sent to a database engine; identifiers and syntax are machine inputs'
    'command-source'      = 'complete command or interpreter source text evaluated by a subprocess; translating it would change executable behavior'
    'test-assertion'      = 'test/assertion rationale consumed only by developer verification, excluded from product localization'
    'regex-body'          = 'a regular-expression body, where the characters are a pattern and not words'
    'comparison-operand'  = 'compared against text produced elsewhere, so its spelling is a protocol that translating would break'
    'attribute-argument'  = 'an argument to a declaration attribute, which the language reads and no reader ever sees'
    'format-template'     = 'a template skeleton whose words are almost entirely substitutions'
    'path-or-command'     = 'a path or a command line, which is a machine value that must stay invariant'
    'catalog-argument'    = 'literal catalog identity selected by the Key parameter; display argument values are reviewed separately'
}
$ConvertReason = [ordered]@{
    'catalog-message'  = 'identical to a message an existing source catalog already ships'
    'display-property' = 'assigned straight to a display property that a reader sees'
    'operator-stream'  = 'whole text emitted to an operator output, warning, information, progress, or prompt surface'
    'exception-text'   = 'human-readable failure condition requiring a catalog message and stable condition identity'
    'display-result'   = 'human-readable description, remediation, label, or finding stored for later operator presentation'
}
# Rule precedence when a literal sits inside more than one context of the same
# size. Catalog arguments first: a key that happens to read like a sentence is
# still a key.
$RulePrecedence = @('catalog-argument', 'display-property', 'display-result', 'attribute-argument', 'regex-body',
    'comparison-operand', 'operator-stream', 'exception-text', 'diagnostic-stream', 'test-assertion')

function Get-RuleReason {
    <#
    .SYNOPSIS
        The sentence that explains one rule's verdict.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Rule,
        [AllowNull()]$Decision
    )

    if ($InternalReason.Contains($Rule)) { return [string]$InternalReason[$Rule] }
    if ($ConvertReason.Contains($Rule)) { return [string]$ConvertReason[$Rule] }
    if ($Rule -eq 'recorded-decision') {
        $why = if ($Decision) { [string]$Decision.reason } else { '' }
        if ($why) { return $why }
        return 'resolved by hand'
    }
    return ''
}

# Distinctive regular-expression tokens. Prose contains dots and pipes, so the
# shape test asks for constructs that only a pattern has.
$RegexToken = '\\[dswbAZ]|\(\?|\[\^|\.\*|\.\+|\\\.|\{\d+,|\\\(|\\\['
# Substitution shapes across the three languages: composite formatting, catalog
# placeholders, PowerShell expansion, printf verbs.
$SubstitutionToken = '\{\d+(?::[^}]*)?\}|\{[A-Za-z][A-Za-z0-9]*\}|\$\([^)]*\)|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|%[+\-#0-9.]*[sdvqtxfbcTw]'
# A path segment or a switch, as they appear inside a larger string.
$MachineToken = '\S*[\\/]\S+|(?<![A-Za-z0-9])-{1,2}[A-Za-z][A-Za-z0-9-]*'

function Measure-BareWord {
    <#
    .SYNOPSIS
        How many whitespace-separated pieces still carry a letter once the
        machine-shaped pieces are removed.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Pattern)

    $bare = [regex]::Replace($Text, $Pattern, ' ')
    return @($bare -split '\s+' | Where-Object { $_ -match '[A-Za-z]' }).Count
}

function Get-ShapeRule {
    <#
    .SYNOPSIS
        The internal rule a literal earns from its own characters, or ''.
    .DESCRIPTION
        Each shape rule asks the same question: with the machine-shaped pieces
        taken out, is there still a sentence here? A path or a placeholder
        inside real prose is normal -- "Copy it to /var/log and retry" is
        something a reader acts on -- so a rule only fires when removing those
        pieces leaves nothing anybody would read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $t = $Text.Trim()
    if ($t -match '(?is)^\s*(?:SELECT\s+.+\s+FROM\s|(?:CREATE|ALTER|DROP)\s+(?:TABLE|INDEX|VIEW)\b|INSERT\s+INTO\s|UPDATE\s+[^\s]+\s+SET\s|DELETE\s+FROM\s|PRAGMA\s|EXPLAIN\s+SELECT\s)') { return 'sql-statement' }
    if ($t -match '(?s)^\s*(?:sudo\s+)?(?:systemctl|launchctl|netsh|reg\s+(?:add|query)|powershell(?:\.exe)?|pwsh|bash|sh|python[23]?|osascript|virsh|VBoxManage|docker|kubectl|helm|tofu|terraform|ssh|scp|curl|wget|git)\s+(?:--?[A-Za-z]|[a-z][a-z-]*\s)') { return 'command-source' }
    if ($t -match $RegexToken) { return 'regex-body' }
    if ($t -match $MachineToken -and (Measure-BareWord -Text $t -Pattern $MachineToken) -lt 2) { return 'path-or-command' }
    if ($t -match $SubstitutionToken -and (Measure-BareWord -Text $t -Pattern $SubstitutionToken) -lt 2) { return 'format-template' }
    return ''
}

function Get-PowerShellContextRange {
    <#
    .SYNOPSIS
        Source spans in a PowerShell file whose literals are classified by where
        they sit.
    .DESCRIPTION
        A literal's meaning comes from the call it reaches, and the parser
        already knows that. Matching text against the line instead would miss
        every call broken over two lines and every "-f" applied to a message
        several characters away from its cmdlet.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast)

    $ranges = [Collections.Generic.List[object]]::new()
    foreach ($node in @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))) {
        $name = $node.GetCommandName()
        if (-not $name) { continue }
        $tag = switch -Regex ($name) {
            '^(Write-Verbose|Write-Debug)$' { 'diagnostic-stream' }
            '^(Write-Host|Write-Information|Write-Progress|Write-Warning|Write-Output|Read-Host|Write-Pass|Write-Fail|Write-Warn|Write-Info|Write-Section)$' { 'operator-stream' }
            '^(Assert-[A-Za-z]+|Should|It|Describe|Context)$' { 'test-assertion' }
            '^(Write-Error)$' { 'exception-text' }
            '^(Format-CatalogMessage|Format-YurunaOperatorMessage|Get-CatalogMessage|Import-Catalog|Resolve-CatalogMessage)$' { 'catalog-argument' }
            default { '' }
        }
        if (-not $tag) { continue }
        if ($tag -eq 'catalog-argument') {
            # Arguments can contain authored choice labels. Only the identity
            # is already translated; treating the whole call as internal hides
            # English branches nested inside an otherwise localized message.
            $elements = $node.CommandElements
            for ($index = 1; $index -lt $elements.Count - 1; $index++) {
                if ($elements[$index] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$index].ParameterName -eq 'Key') {
                    $key = $elements[$index + 1]
                    $ranges.Add([pscustomobject]@{ Start = $key.Extent.StartOffset; End = $key.Extent.EndOffset; Tag = $tag })
                }
            }
            continue
        }
        $ranges.Add([pscustomobject]@{ Start = $node.Extent.StartOffset; End = $node.Extent.EndOffset; Tag = $tag })
    }
    foreach ($node in @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.ThrowStatementAst] }, $true))) {
        $ranges.Add([pscustomobject]@{ Start = $node.Extent.StartOffset; End = $node.Extent.EndOffset; Tag = 'exception-text' })
    }
    # Only the right operand: the left of "-match" is the subject being tested
    # and is frequently the operator text itself.
    foreach ($node in @($Ast.FindAll({
                    param($n)
                    $n -is [Management.Automation.Language.BinaryExpressionAst] -and
                    $n.Operator -in @('Imatch', 'Inotmatch', 'Ireplace', 'Isplit', 'Cmatch', 'Cnotmatch', 'Creplace', 'Csplit')
                }, $true))) {
        $ranges.Add([pscustomobject]@{ Start = $node.Right.Extent.StartOffset; End = $node.Right.Extent.EndOffset; Tag = 'regex-body' })
    }
    # Either side of an equality or containment test. A literal being compared
    # is a value some other program produced, and its spelling is the contract
    # between the two -- translating it silently changes which branch runs.
    foreach ($node in @($Ast.FindAll({
                    param($n)
                    $n -is [Management.Automation.Language.BinaryExpressionAst] -and
                    $n.Operator -in @('Ieq', 'Ine', 'Ilike', 'Inotlike', 'Icontains', 'Inotcontains', 'Iin', 'Inotin',
                        'Ceq', 'Cne', 'Clike', 'Cnotlike', 'Ccontains', 'Cnotcontains', 'Cin', 'Cnotin')
                }, $true))) {
        $ranges.Add([pscustomobject]@{ Start = $node.Extent.StartOffset; End = $node.Extent.EndOffset; Tag = 'comparison-operand' })
    }
    foreach ($node in @($Ast.FindAll({
                    param($n)
                    $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                    [string]$n.Member.Value -in @('Contains', 'IndexOf', 'LastIndexOf', 'StartsWith', 'EndsWith', 'Equals')
                }, $true))) {
        $ranges.Add([pscustomobject]@{ Start = $node.Extent.StartOffset; End = $node.Extent.EndOffset; Tag = 'comparison-operand' })
    }
    # Attribute arguments are read by the language itself: a validation set, an
    # output type, the justification on a suppressed analyzer rule. They look
    # like sentences and reach no screen.
    foreach ($node in @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.AttributeAst] }, $true))) {
        $ranges.Add([pscustomobject]@{ Start = $node.Extent.StartOffset; End = $node.Extent.EndOffset; Tag = 'attribute-argument' })
    }
    foreach ($node in @($Ast.FindAll({
                    param($n)
                    $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                    $n.Expression.TypeName.Name -match '(^|\.)regex$'
                }, $true))) {
        $ranges.Add([pscustomobject]@{ Start = $node.Extent.StartOffset; End = $node.Extent.EndOffset; Tag = 'regex-body' })
    }
    foreach ($node in @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true))) {
        foreach ($pair in $node.KeyValuePairs) {
            $name = [string]$pair.Item1.Value
            if ($name -imatch '^(description|displayName|title|label|summary|hint|remediation|guidance|humanMessage)$') {
                $ranges.Add([pscustomobject]@{ Start = $pair.Item2.Extent.StartOffset; End = $pair.Item2.Extent.EndOffset; Tag = 'display-result' })
            }
        }
    }
    return $ranges.ToArray()
}

function Get-RangeTag {
    <#
    .SYNOPSIS
        The tag of the tightest span containing an offset.
    .DESCRIPTION
        Tightest, because a Write-Verbose wrapping a comparison says less about
        the compared pattern than the comparison does. Ties break on a fixed
        precedence so the recorded rule does not depend on enumeration order.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Range,
        [Parameter(Mandatory)][int]$Offset
    )

    $best = ''
    $bestSpan = [int]::MaxValue
    $bestRank = [int]::MaxValue
    foreach ($r in $Range) {
        if ($Offset -lt $r.Start -or $Offset -ge $r.End) { continue }
        $span = $r.End - $r.Start
        $rank = $RulePrecedence.IndexOf([string]$r.Tag)
        if ($rank -lt 0) { $rank = $RulePrecedence.Count }
        if ($span -lt $bestSpan -or ($span -eq $bestSpan -and $rank -lt $bestRank)) {
            $best = [string]$r.Tag
            $bestSpan = $span
            $bestRank = $rank
        }
    }
    return $best
}

# What the text immediately before a scanned literal says about it. The window
# is short and anchored at the literal, so a call three statements earlier
# cannot claim it.
$ScannedContext = @(
    [pscustomobject]@{ Tag = 'catalog-argument'; Pattern = '(YurunaI18n\.t|Yuruna\.t|catalog\.Render|Translate)\(\s*[^)\n]*$' }
    [pscustomobject]@{ Tag = 'display-property'; Pattern = '(\b(text|title|label|ariaLabel|placeholder|alt|caption|summary)\s*:\s*|\.(textContent|innerText|title|placeholder|ariaLabel)\s*=\s*|setAttribute\(\s*.aria-label.\s*,\s*)$' }
    [pscustomobject]@{ Tag = 'regex-body'; Pattern = '(regexp\.MustCompile|new RegExp)\(\s*$' }
    [pscustomobject]@{ Tag = 'comparison-operand'; Pattern = '(={2,3}|!={1,2}|\.(includes|indexOf|startsWith|endsWith)\(|strings\.(Contains|HasPrefix|HasSuffix|EqualFold|Index)\([^,\n]*,)\s*$' }
    [pscustomobject]@{ Tag = 'exception-text'; Pattern = '(throw new [A-Za-z]*|fmt\.Errorf|errors\.New|panic)\(\s*[^)\n]*$' }
    [pscustomobject]@{ Tag = 'diagnostic-stream'; Pattern = '(console\.(log|debug|warn|error|info|trace)|log\.(Printf|Print|Println|Fatalf|Fatal)|slog\.[A-Za-z]+)\(\s*[^)\n]*$' }
)

function Get-ScannedContextTag {
    <#
    .SYNOPSIS
        The tag implied by the source text leading up to a scanned literal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Before)

    foreach ($rule in $ScannedContext) {
        if ($Before -match $rule.Pattern) { return [string]$rule.Tag }
    }
    return ''
}

# --- REGION: Candidate extraction
function Get-CandidateId {
    <#
    .SYNOPSIS
        The stable identity of one distinct literal inside one domain.
    .DESCRIPTION
        Domain-scoped on purpose: the same sentence can be a log line in the
        runner and a label in the status page, and one decision must not travel
        between them. Occurrence is not part of it, so a decision covers every
        copy of the text at once.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DomainName, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes("$DomainName|$Text")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant().Substring(0, 16) }
    finally { $sha.Dispose() }
}

function Get-FileCandidate {
    <#
    .SYNOPSIS
        Every prose candidate in one source file, with the context that
        classifies it.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Extension
    )

    $text = [IO.File]::ReadAllText($Path)
    $found = [Collections.Generic.List[object]]::new()

    if ($Extension -in '.ps1', '.psm1') {
        $tokens = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$null)
        $ranges = @(Get-PowerShellContextRange -Ast $ast)
        $bootstrap = $Path.Replace('\', '/') -match '/(?:install/windows\.hyper-v\.ps1|automation/windows-guest-bootstrap\.ps1|guest/windows\.11/[^/]+\.ps1)$'
        foreach ($token in @($tokens)) {
            if ($token.Kind -ne 'StringLiteral' -and $token.Kind -ne 'StringExpandable') { continue }
            if ($null -eq $token.Value) { continue }
            $value = [string]$token.Value
            if (-not (Test-IsProseCandidate -Text $value)) { continue }
            $found.Add([pscustomobject]@{
                    Text = $value
                    Line = $token.Extent.StartLineNumber
                    Tag  = if ($bootstrap) { 'bootstrap-english' } else { Get-RangeTag -Range $ranges -Offset $token.Extent.StartOffset }
                })
        }
        return $found.ToArray()
    }

    # The scanner owns which literals exist; walking forward through the text
    # only says where each of them is. A literal whose source form was escaped
    # is not found again by value, and then it simply has no context -- which
    # leaves it unexplained, the safe direction.
    $literals = @(Get-ScannedStringLiteral -Text $text -BacktickRaw:($Extension -eq '.go'))
    $cursor = 0
    $counted = 0
    $line = 1
    foreach ($literal in $literals) {
        $index = -1
        if ($literal) { $index = $text.IndexOf($literal, $cursor, [StringComparison]::Ordinal) }
        $before = ''
        if ($index -ge 0) {
            # Counted from the previous literal's start rather than its end, so
            # the newlines inside a raw or template literal are not skipped and
            # every line number after one stays right.
            $line += @([regex]::Matches($text.Substring($counted, $index - $counted), "`n")).Count
            $counted = $index
            # The window stops one character short of the value, because that
            # character is the opening quote. Leaving it in defeats every
            # context pattern that asks what sits immediately before a literal.
            $end = $index - 1
            $start = [Math]::Max(0, $end - 160)
            if ($end -gt $start) { $before = $text.Substring($start, $end - $start) }
            $cursor = $index + $literal.Length
        }
        if (-not (Test-IsProseCandidate -Text $literal)) { continue }
        $found.Add([pscustomobject]@{
                Text = $literal
                Line = $line
                Tag  = if ($before) { Get-ScannedContextTag -Before $before } else { '' }
            })
    }
    return $found.ToArray()
}

function Get-DomainCandidate {
    <#
    .SYNOPSIS
        Every candidate in one domain, keyed by distinct text.
    .DESCRIPTION
        File selection repeats the inventory's rules exactly -- tracked and
        untracked sources, no test suites, only the four languages it reads --
        so the occurrence total here is the inventory's candidate total for the
        domain.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Definition,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TrackedFile
    )

    $result = [ordered]@{ files = 0; occurrences = 0; candidates = [ordered]@{} }
    foreach ($rel in @($Definition.Paths)) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $rel) -PathType Container)) { continue }
        foreach ($relative in @($TrackedFile | Where-Object { $_ -eq $rel -or $_.StartsWith("$rel/") })) {
            $full = Join-Path $RepoRoot $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $file = [IO.FileInfo]::new($full)
            if ($file.Name -match '(\.Tests\.ps1|_test\.go|\.test\.js)$') { continue }
            $ext = $file.Extension.ToLowerInvariant()
            if ($ext -notin '.ps1', '.psm1', '.js', '.go') { continue }

            $hits = @(Get-FileCandidate -Path $full -Extension $ext)
            if ($hits.Count -eq 0) { $result.files++; continue }
            $result.files++
            $result.occurrences += $hits.Count
            foreach ($hit in $hits) {
                $key = [string]$hit.Text
                if (-not $result.candidates.Contains($key)) {
                    $result.candidates[$key] = [ordered]@{
                        file = $relative; line = [int]$hit.Line; occurrences = 0
                        tag = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    }
                }
                $entry = $result.candidates[$key]
                $entry.occurrences++
                if ($hit.Tag) { [void]$entry.tag.Add([string]$hit.Tag) }
            }
        }
    }
    return $result
}

# --- REGION: Manifest input
function Get-RecordedManifest {
    <#
    .SYNOPSIS
        The decisions and emitted messages already on record, or empty maps.
    .DESCRIPTION
        Read in every mode. A gate that ignored recorded decisions would never
        go green no matter how much work a person did.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $empty = @{ Decisions = [ordered]@{}; Messages = [ordered]@{} }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    if ([string]$doc.schema -cne 'yuruna.candidate-triage/v1') {
        throw "$Path declares schema '$($doc.schema)', not yuruna.candidate-triage/v1"
    }
    # Property order is carried across untouched. Re-ordering what was read
    # would rewrite a record this tool is only allowed to add to, and the next
    # run would then differ from this one on unchanged input.
    foreach ($pair in @(@{ Name = 'decisions'; Key = 'Decisions' }, @{ Name = 'messages'; Key = 'Messages' })) {
        $section = $doc.($pair.Name)
        if ($null -eq $section) { continue }
        foreach ($property in @($section.PSObject.Properties)) {
            $value = [ordered]@{}
            foreach ($inner in @($property.Value.PSObject.Properties)) { $value[$inner.Name] = $inner.Value }
            $empty[$pair.Key][$property.Name] = $value
        }
    }
    return $empty
}

function Get-CatalogMessageText {
    <#
    .SYNOPSIS
        Every sentence the source catalogs already ship, for exact matching.
    #>
    [CmdletBinding()]
    [OutputType([Collections.Generic.HashSet[string]])]
    param([Parameter(Mandatory)][string]$Path)

    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    # Written without enumeration on the way out: a bare set is unrolled into
    # the output stream and the caller receives its members instead of the set.
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Output -NoEnumerate -InputObject $set
        return
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object Name)) {
        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName))
        foreach ($property in @($catalog.messages.PSObject.Properties)) {
            $message = $property.Value
            if ($null -ne $message.message) { [void]$set.Add([string]$message.message) }
            foreach ($kind in @('plural', 'select')) {
                if ($null -eq $message.$kind) { continue }
                foreach ($variant in @($message.$kind.variants.PSObject.Properties)) {
                    [void]$set.Add([string]$variant.Value)
                }
            }
        }
    }
    Write-Output -NoEnumerate -InputObject $set
}

# --- REGION: Message proposal
function Get-CatalogDomainName {
    <#
    .SYNOPSIS
        The catalog namespace a domain's messages live under.
    .DESCRIPTION
        Catalog domains are dotted lower-case segments, so a hyphenated domain
        becomes a dotted one. Anything else would be refused by the catalog
        schema after the file was already written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DomainName)
    return ($DomainName -replace '-', '.')
}

function Get-MessageKey {
    <#
    .SYNOPSIS
        A deterministic catalog key for one proposed message.
    .DESCRIPTION
        Derived from the domain and the text, so re-running produces the same
        key and a reworded sentence produces a new one rather than silently
        replacing a message a translator has already worked on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DomainName, [Parameter(Mandatory)][string]$Text)
    return (Get-CatalogDomainName -DomainName $DomainName) + '.m' + (Get-CandidateId -DomainName $DomainName -Text $Text).Substring(0, 10)
}

# --- REGION: Start
try {

if ($Update -and $PSBoundParameters.ContainsKey('Check') -and $Check) {
    throw 'choose either -Check or -Update; they are different modes'
}
if ($Decide -and -not $Update) { throw '-Decide records a decision, so it needs -Update' }
if ($Decide -and (-not $As -or -not $Reason)) { throw '-Decide needs both -As and -Reason, so the record is reviewable' }
if ($Domain -and $Update -and -not $PSBoundParameters.ContainsKey('OutputPath')) {
    throw '-Domain with -Update would narrow the shared manifest to one domain; give -OutputPath a scratch path instead'
}
if ($EmitCatalog -and -not $Update) { throw '-EmitCatalog writes catalogs, so it needs -Update' }
if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
    throw "the domain inventory this tool reuses is missing: $InventoryPath"
}
. ([scriptblock]::Create((Get-SharedDefinition -Path $InventoryPath)))

$wanted = @($Domains | Where-Object { [string]$_.Repo -eq 'yuruna' })
if ($Domain) {
    $wanted = @($wanted | Where-Object { [string]$_.Name -ceq $Domain })
    if ($wanted.Count -eq 0) { throw "no literal-bearing domain is named '$Domain'" }
}
# The project repository's candidates are parsed YAML display fields and
# documents, not source literals. They convert through the project locale-map
# contract, so they are named here and counted nowhere, rather than being
# quietly folded into a literal total they are not part of.
$untriaged = @($Domains | Where-Object { [string]$_.Repo -ne 'yuruna' } | ForEach-Object {
        [ordered]@{
            domain     = [string]$_.Name
            repository = [string]$_.Repo
            lane       = 'locale-map'
            reason     = 'display metadata and documents convert through the project locale-map contract, not through a message catalog'
        }
    })

Push-Location $RepoRoot
try { $tracked = @(& git ls-files --cached --others --exclude-standard) } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "git could not enumerate source in $RepoRoot" }
$tracked = @($tracked | Sort-Object -Unique)

$recorded = Get-RecordedManifest -Path $OutputPath
$shipped = Get-CatalogMessageText -Path $CatalogRoot

# A decision recorded by a person is the record; the classifier only fills the
# gaps around it.
foreach ($id in @($Decide)) {
    if (-not $id) { continue }
    $recorded.Decisions[$id] = [ordered]@{ disposition = $As; reason = $Reason }
}

# --- REGION: Classify
$rows = [Collections.Generic.List[object]]::new()
$candidates = [Collections.Generic.List[object]]::new()
$proposed = [ordered]@{}
$ruleCount = [ordered]@{}
foreach ($rule in @($InternalReason.Keys) + @($ConvertReason.Keys) + @('recorded-decision')) { $ruleCount[$rule] = 0 }

foreach ($definition in $wanted) {
    $name = [string]$definition.Name
    $scan = Get-DomainCandidate -Definition $definition -TrackedFile $tracked
    $row = [ordered]@{
        domain = $name; repository = 'yuruna'; lane = 'catalog'
        files = [int]$scan.files; occurrences = [int]$scan.occurrences
        candidates = 0; convert = 0; internal = 0; unexplained = 0
    }
    foreach ($text in @(Get-OrdinalOrder -Value @($scan.candidates.Keys))) {
        $entry = $scan.candidates[$text]
        $id = Get-CandidateId -DomainName $name -Text $text
        $row.candidates++

        $disposition = ''
        $rule = ''
        if ($recorded.Decisions.Contains($id)) {
            $disposition = [string]$recorded.Decisions[$id].disposition
            $rule = 'recorded-decision'
        } else {
            # One context, or none. A sentence that is a log line in one place
            # and a label in another has no single answer, and picking whichever
            # copy the file walk reached first would make the verdict depend on
            # file order rather than on the text.
            $tag = if ($entry.tag.Count -eq 1) { @($entry.tag)[0] } else { '' }
            if ($tag -and $InternalReason.Contains($tag)) {
                $disposition = 'internal'; $rule = $tag
            } elseif ($tag -and $ConvertReason.Contains($tag)) {
                $disposition = 'convert'; $rule = $tag
            } elseif ($shipped.Contains($text.Trim())) {
                $disposition = 'convert'; $rule = 'catalog-message'
            } elseif ($entry.tag.Count -eq 0) {
                $shape = Get-ShapeRule -Text $text
                if ($shape) { $disposition = 'internal'; $rule = $shape }
            }
        }

        switch ($disposition) {
            'internal' { $row.internal++ }
            'convert' { $row.convert++ }
            default { $disposition = 'unexplained'; $row.unexplained++ }
        }
        if ($rule) { $ruleCount[$rule] = [int]$ruleCount[$rule] + 1 }
        # Every candidate is written down with the rule that decided it and the
        # sentence that rule was applied to. A count by rule would say how often
        # the classifier fired and never let anybody check whether it was right,
        # which is the only question a reviewer of this manifest has.
        $candidates.Add([ordered]@{
                id = $id; domain = $name; file = [string]$entry.file; line = [int]$entry.line
                occurrences = [int]$entry.occurrences; disposition = $disposition; rule = $rule
                reason = Get-RuleReason -Rule $rule -Decision $(if ($rule -eq 'recorded-decision') { $recorded.Decisions[$id] } else { $null })
                text = $text
            })

        if ($disposition -ne 'convert') { continue }
        $key = Get-MessageKey -DomainName $name -Text $text
        if ($recorded.Messages.Contains($key)) { continue }
        # Operator-facing and still not ready to ship as it stands. A piece of a
        # sentence concatenated with a value at run time cannot be translated
        # until the whole sentence exists in one place -- word order is not the
        # same in every language and a fragment cannot be reordered. A sentence
        # carrying an argument needs that argument declared and typed first, and
        # guessing a type is how a number reaches a reader formatted for the
        # wrong locale. Both are recorded as proposals a person completes.
        $state = if (Test-IsSentenceFragment -Text $text) { 'needs-recomposition' }
        elseif ($text -match '\{[A-Za-z]') { 'needs-placeholders' }
        else { 'ready' }
        $proposed[$key] = [ordered]@{
            id = $id; domain = $name; catalogDomain = (Get-CatalogDomainName -DomainName $name)
            file = [string]$entry.file; rule = $rule; state = $state; text = $text
        }
    }
    $rows.Add($row)
}

# Additive: what was emitted before stays exactly as it was, and this run can
# only add. Nothing here rewrites a message a translator may already hold.
$messages = [ordered]@{}
foreach ($key in @(@($recorded.Messages.Keys) + @($proposed.Keys) | Sort-Object -CaseSensitive -Unique)) {
    $messages[$key] = if ($recorded.Messages.Contains($key)) { $recorded.Messages[$key] } else { $proposed[$key] }
}
$decisions = [ordered]@{}
foreach ($id in @($recorded.Decisions.Keys | Sort-Object -CaseSensitive)) { $decisions[$id] = $recorded.Decisions[$id] }

$rules = @(foreach ($rule in @($ruleCount.Keys)) {
        if ([int]$ruleCount[$rule] -eq 0) { continue }
        $disposition = if ($InternalReason.Contains($rule)) { 'internal' }
        elseif ($ConvertReason.Contains($rule)) { 'convert' }
        else { 'decided' }
        [ordered]@{
            rule = $rule; disposition = $disposition
            reason = Get-RuleReason -Rule $rule -Decision $null
            candidates = [int]$ruleCount[$rule]
        }
    })

$totals = [ordered]@{
    domains     = $rows.Count
    files       = [int](@($rows | ForEach-Object { [int]$_.files } | Measure-Object -Sum).Sum)
    occurrences = [int](@($rows | ForEach-Object { [int]$_.occurrences } | Measure-Object -Sum).Sum)
    candidates  = [int](@($rows | ForEach-Object { [int]$_.candidates } | Measure-Object -Sum).Sum)
    convert     = [int](@($rows | ForEach-Object { [int]$_.convert } | Measure-Object -Sum).Sum)
    internal    = [int](@($rows | ForEach-Object { [int]$_.internal } | Measure-Object -Sum).Sum)
    unexplained = [int](@($rows | ForEach-Object { [int]$_.unexplained } | Measure-Object -Sum).Sum)
    decided     = $decisions.Count
    messages    = $messages.Count
}

$doc = [ordered]@{
    schema     = 'yuruna.candidate-triage/v1'
    note       = 'Disposition of every candidate literal the domain inventory finds, one entry per distinct text per domain. Only unexplained is work: convert belongs in a catalog, internal carries the rule and the reason that rule it out, and a recorded decision outranks the classifier.'
    generator  = 'tools/Invoke-CatalogTriage.ps1'
    scope      = [ordered]@{
        domains   = @($rows | ForEach-Object { [string]$_.domain })
        untriaged = @($untriaged)
    }
    totals     = $totals
    rules      = @($rules)
    domains    = @($rows)
    decisions  = $decisions
    candidates = @($candidates)
    messages   = $messages
}
$json = ((ConvertTo-Json -InputObject $doc -Depth 8) -replace "`r`n", "`n").TrimEnd() + "`n"

# --- REGION: Report and record
if (-not $Quiet) {
    $format = "{0,-18} {1,6} {2,9} {3,11} {4,8} {5,9} {6,12}"
    Write-Output ($format -f 'DOMAIN', 'FILES', 'LITERALS', 'CANDIDATES', 'CONVERT', 'INTERNAL', 'UNEXPLAINED')
    foreach ($row in $rows) {
        Write-Output ($format -f $row.domain, $row.files, $row.occurrences, $row.candidates,
            $row.convert, $row.internal, $row.unexplained)
    }
    # Named, not counted. Leaving them off the report entirely would make the
    # totals here look like a smaller tree than the inventory measures.
    foreach ($row in $untriaged) {
        Write-Output ("{0,-18} not triaged here: {1}" -f $row.domain, $row.reason)
    }
}

if ($Update) {
    $written = @()
    if ($PSCmdlet.ShouldProcess($OutputPath, 'record the candidate triage')) {
        $directory = Split-Path -Parent $OutputPath
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        [IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
        $written += $OutputPath
    }
    if ($EmitCatalog) {
        foreach ($catalogDomain in @($messages.Values | ForEach-Object { [string]$_.catalogDomain } | Sort-Object -Unique)) {
            $emit = @($messages.GetEnumerator() |
                Where-Object { [string]$_.Value.catalogDomain -eq $catalogDomain -and [string]$_.Value.state -eq 'ready' })
            if ($emit.Count -eq 0) { continue }
            $file = Join-Path $CatalogRoot "$catalogDomain.json"
            $catalog = [ordered]@{
                schema = 'yuruna.catalog/v1'; domain = $catalogDomain; locale = 'en-US'; messages = [ordered]@{}
            }
            $existing = [ordered]@{}
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $current = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file))
                foreach ($property in @($current.messages.PSObject.Properties)) { $existing[$property.Name] = $property.Value }
            }
            $added = 0
            foreach ($pair in $emit) {
                if ($existing.Contains($pair.Key)) { continue }
                $existing[$pair.Key] = [ordered]@{
                    message     = [string]$pair.Value.text
                    description = "Operator-facing text in $($pair.Value.file). Proposed by triage; a reviewer replaces this with what a translator needs to know."
                    lifecycle   = 'active'
                }
                $added++
            }
            if ($added -eq 0) { continue }
            foreach ($key in @($existing.Keys | Sort-Object -CaseSensitive)) { $catalog.messages[$key] = $existing[$key] }
            if (-not $PSCmdlet.ShouldProcess($file, "add $added proposed message(s)")) { continue }
            if (-not (Test-Path -LiteralPath $CatalogRoot -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $CatalogRoot -Force
            }
            [IO.File]::WriteAllText($file, ((ConvertTo-Json -InputObject $catalog -Depth 8) -replace "`r`n", "`n").TrimEnd() + "`n",
                [Text.UTF8Encoding]::new($false))
            $written += $file
        }
    }
    if (-not $Quiet) { foreach ($path in $written) { Write-Output "WROTE $path" } }
}

} catch {
    $ErrorActionPreference = 'Continue'
    Write-Error $_.Exception.Message
    exit 2
}

Write-Output ("Invoke-CatalogTriage: {0} distinct candidate(s) from {1} occurrence(s) across {2} file(s); {3} convert, {4} internal, {5} unexplained ({6} decided by hand)." -f
    $totals.candidates, $totals.occurrences, $totals.files, $totals.convert, $totals.internal, $totals.unexplained, $totals.decided)

if ($Update) { exit 0 }

if ($totals.unexplained -gt 0) {
    Write-Output "FINDING: $($totals.unexplained) candidate(s) are unexplained; each needs a disposition before the conversion metric can reach zero."
    if (-not $Quiet) {
        foreach ($row in @($candidates | Where-Object { $_.disposition -eq 'unexplained' } | Select-Object -First 10)) {
            $sample = if ($row.text.Length -gt 72) { $row.text.Substring(0, 69) + '...' } else { $row.text }
            Write-Output ("  {0}  {1}:{2}  {3}" -f $row.id, $row.file, $row.line, $sample)
        }
        Write-Output '  Resolve one with: -Update -Decide <id> -As <convert|internal> -Reason <text>'
    }
    exit 1
}
exit 0
