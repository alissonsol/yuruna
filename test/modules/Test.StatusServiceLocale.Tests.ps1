<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42d1c86a-7fb3-4e59-90a2-63b4e0d7185f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization status service negotiation pester
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
    Run the status service's own language negotiation, out of the script it
    actually generates.
.DESCRIPTION
    The server is emitted from a here-string, so what runs on a host is not
    this file -- it is the text this file produces. Reading the template would
    prove the intent and not the artifact, and the difference is exactly where
    a missing backtick hides: a variable that expanded at generation time looks
    correct in the template and is a constant in the thing that runs.

    So the here-string is expanded the way the launcher expands it, the
    negotiation function is lifted out of the result, and it is called. What is
    asserted is the behavior of the code that will be on the host.

    The rules are the ones every runtime here shares. A q of zero is a refusal
    rather than a weak preference. A pseudo locale is refused unless the run
    asked for one, because a reader who received expanded or mirrored text
    would read the page as broken rather than as translated.

    Run: Invoke-Pester -Path test/modules/Test.StatusServiceLocale.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Catalog.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Locale.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:ServicePath = Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1'

# The generated server, produced the way the launcher produces it. The
# here-string interpolates whatever the launcher had in scope; none of that
# matters to the function under test, so the surrounding names are bound to
# harmless values and the expansion is what is inspected.
function Get-GeneratedServerText {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $lines = [IO.File]::ReadAllLines($script:ServicePath)
    $start = -1; $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match '^\$serverScript = @"$') { $start = $i + 1; continue }
        if ($start -ge 0 -and $lines[$i] -match '^"@$') { $end = $i - 1; break }
    }
    if ($start -lt 0 -or $end -lt $start) { throw 'could not find the server here-string in the launcher' }
    $raw = ($lines[$start..$end]) -join "`n"
    # Expanded, not merely read. The template writes every runtime variable
    # with a leading backtick so it survives generation; reading the template
    # would leave those backticks in place and parse as something the host
    # never runs. ExpandString performs exactly the interpolation the
    # here-string performs, which is what turns the template into the artifact
    # -- and is why a variable that LOST its backtick shows up here as the
    # constant it became rather than as the name it looks like.
    return $ExecutionContext.InvokeCommand.ExpandString($raw)
}

$script:ServerText = Get-GeneratedServerText

function Get-FunctionFromServer {
    <#
    .SYNOPSIS
        One function, lifted out of the generated server and made callable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:ServerText, [ref]$null, [ref]$null)
    $found = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $found) { return '' }
    return $found.Extent.Text
}

function Get-DirectoryListingBlockFromServer {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $startMarker = '$sb = [System.Text.StringBuilder]::new()'
    $endMarker = "'</main></body></html>')"
    $start = $script:ServerText.IndexOf($startMarker, [StringComparison]::Ordinal)
    $end = $script:ServerText.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt $start) { throw 'directory-listing block not found in emitted server' }
    return $script:ServerText.Substring($start, ($end - $start) + $endMarker.Length)
}

$script:ServerAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $script:ServerText, [ref]$null, [ref]$null)

function Get-StringConstant {
    <#
    .SYNOPSIS
        Every literal string inside one command argument, whatever shape it
        was written in.
    .DESCRIPTION
        An argument list is written three ways in this server -- one bare
        string, a comma list, and a parenthesized @() -- which parse to three
        different node types. Searching the argument subtree instead of
        matching its top node reads all three the same way, so a caller can
        stop caring which one an author picked.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Argument)

    return , @($Argument.FindAll({
                param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { $_.Value })
}

function Get-CommandArgumentValue {
    <#
    .SYNOPSIS
        The literal strings passed to one named parameter of one command.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory)][string]$ParameterName
    )

    $values = [System.Collections.Generic.List[string]]::new()
    $collecting = $false
    foreach ($element in $Command.CommandElements) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $collecting = ($element.ParameterName -eq $ParameterName)
            if ($collecting -and $element.Argument) {
                foreach ($value in (Get-StringConstant -Argument $element.Argument)) { $values.Add($value) }
                $collecting = $false
            }
            continue
        }
        if (-not $collecting) { continue }
        foreach ($value in (Get-StringConstant -Argument $element)) { $values.Add($value) }
    }
    return , $values.ToArray()
}

function Get-ServerPrologueImport {
    <#
    .SYNOPSIS
        The startup Import-Module statements of the generated server, in the
        order its runspace runs them.
    .DESCRIPTION
        The prologue is everything above the first function definition: it
        runs once, before the listener exists, so it is the whole of what the
        detached runspace has when the first request arrives. The on-demand
        re-import inside the route helper is below that boundary and is not
        part of it -- it names its module through a parameter and runs per
        request, which is a different contract.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $firstFunction = @($script:ServerAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    if ($firstFunction.Count -eq 0) {
        throw 'the generated server defines no function, so its startup prologue has no lower bound'
    }
    $boundary = $firstFunction[0].Extent.StartOffset

    $imports = @($script:ServerAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Import-Module'
            }, $true) |
            Where-Object { $_.Extent.StartOffset -lt $boundary } |
            Sort-Object { $_.Extent.StartOffset })

    return , @($imports | ForEach-Object {
            $module = ''
            foreach ($literal in (Get-StringConstant -Argument $_)) {
                if ($literal -match '^test/modules/[^/]+\.psm1$') { $module = $literal }
            }
            [pscustomobject]@{
                Text = $_.Extent.Text
                Module = $module
                ErrorAction = (@(Get-CommandArgumentValue -Command $_ -ParameterName 'ErrorAction') |
                        Select-Object -First 1)
            }
        })
}

function Get-ModuleExportedCommand {
    <#
    .SYNOPSIS
        The function names one module declares in its Export-ModuleMember.
    .DESCRIPTION
        Read statically rather than by importing: an import answers what this
        runspace happens to hold, and the question here is what the module
        file promises a fresh one.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)

    $names = [System.Collections.Generic.List[string]]::new()
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    foreach ($call in $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Export-ModuleMember'
            }, $true)) {
        foreach ($name in (Get-CommandArgumentValue -Command $call -ParameterName 'Function')) {
            $names.Add($name)
        }
    }
    return , $names.ToArray()
}

function Get-AbortingCatchFromServer {
    <#
    .SYNOPSIS
        The catch clause that tears down a response held by one named
        variable.
    .DESCRIPTION
        More than one place in this server aborts a response, and they are not
        interchangeable: the request loop holds the context in $ctx, the
        archive streamer receives it as its own $Context parameter. The
        receiver is what tells them apart, so it is what selects here --
        matching on the word Abort alone would silently assert about whichever
        one happened to be found first.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.CatchClauseAst])]
    param([Parameter(Mandatory)][string]$ContextVariable)

    $matched = @()
    foreach ($clause in $script:ServerAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.CatchClauseAst]
            }, $true)) {
        $aborts = @($clause.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Member.Value -eq 'Abort'
                }, $true))
        if ($aborts.Count -eq 0) { continue }
        if ($aborts[0].Expression.Extent.Text -ne ($ContextVariable + '.Response')) { continue }
        $matched += $clause
    }
    if ($matched.Count -ne 1) {
        throw ("the generated server has $($matched.Count) catch clauses aborting " +
            "$ContextVariable.Response; exactly one was expected")
    }
    return $matched[0]
}

$script:ServerPrologueImport = Get-ServerPrologueImport

# What a module promises, keyed by command. Two views: everything the prologue
# loads, and the subset the prologue refuses to start without -- the server
# marks those imports -ErrorAction Stop and the rest best-effort, so it has
# already said which commands it treats as load-bearing.
$script:PrologueExport = @{}
$script:MandatoryExport = @{}
foreach ($import in $script:ServerPrologueImport) {
    if (-not $import.Module) { continue }
    foreach ($name in (Get-ModuleExportedCommand -Path (Join-Path $script:RepoRoot $import.Module))) {
        $script:PrologueExport[$name] = $import.Module
        if ($import.ErrorAction -eq 'Stop') { $script:MandatoryExport[$name] = $import.Module }
    }
}

# Commands named to Import-RouteModule are re-imported on the request that
# needs them, so a startup import that lost them is recoverable there. Nothing
# recovers a command that has no such guard.
$script:RouteGuardedCommand = @{}
foreach ($guard in $script:ServerAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Import-RouteModule'
        }, $true)) {
    foreach ($name in (Get-CommandArgumentValue -Command $guard -ParameterName 'RequiredCommand')) {
        $script:RouteGuardedCommand[$name] = $true
    }
}

$script:ServerDefinedFunction = @{}
foreach ($definition in $script:ServerAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)) {
    $script:ServerDefinedFunction[$definition.Name] = $true
}

$script:ServerCalledCommand = @($script:ServerAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -and -not $script:ServerDefinedFunction.ContainsKey($_) } |
        Sort-Object -Unique)

# Every command the server calls that some module here owns. A native tool, a
# platform cmdlet and a command an extension supplies at run time all fall out
# by not being any module's export, which is what keeps this list the same on
# every host rather than a reflection of what happens to be installed.
$script:RepoModuleExport = @{}
foreach ($moduleFile in (Get-ChildItem -LiteralPath $here -Filter '*.psm1' -File)) {
    foreach ($name in (Get-ModuleExportedCommand -Path $moduleFile.FullName)) {
        if (-not $script:RepoModuleExport.ContainsKey($name)) { $script:RepoModuleExport[$name] = @() }
        $script:RepoModuleExport[$name] += $moduleFile.Name
    }
}
$script:ServerModuleCall = @($script:ServerCalledCommand |
        Where-Object { $script:RepoModuleExport.ContainsKey($_) })

# The commands a fresh server runspace has to end up holding, derived from the
# server rather than listed here. A hand-written list goes stale the first time
# a route starts calling something new, and a stale guard is worse than none
# because it still reports green.
#
# Two rules select them. Whatever the server calls out of a module it imports
# -ErrorAction Stop is mandatory by the server's own declaration. And whatever
# the locale resolver calls is mandatory however its module was imported: that
# function runs on every localized route, and it reads the language lock inside
# a try/catch that swallows the loss, so a missing config command degrades the
# page silently rather than failing loudly.
$script:LocaleResolverCall = @()
$script:LocaleResolver = @($script:ServerAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Resolve-PageLocale'
        }, $true) | Select-Object -First 1)
if ($script:LocaleResolver.Count -eq 1) {
    $script:LocaleResolverCall = @($script:LocaleResolver[0].FindAll({
                param($n) $n -is [System.Management.Automation.Language.CommandAst]
            }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}

$script:RequiredServerCommand = @(@(
        @($script:ServerCalledCommand | Where-Object { $script:MandatoryExport.ContainsKey($_) }) +
        @($script:LocaleResolverCall | Where-Object { $script:PrologueExport.ContainsKey($_) })
    ) | Sort-Object -Unique)
}

Describe 'the served page says which language it is in' {

    It 'emits a syntactically valid server script' {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $script:ServerText, [ref]$null, [ref]$parseErrors)

        $findings = @($parseErrors | ForEach-Object {
                "line $($_.Extent.StartLineNumber), column $($_.Extent.StartColumnNumber): $($_.Message)"
            })
        Assert-NoFinding $findings `
            'the expanded server here-string does not parse as the status-service child will parse it'
    }

    It 'lifts the negotiation out of the script the host will actually run' {
        $text = Get-FunctionFromServer -Name 'Resolve-PageLocale'
        Assert-True ([bool]$text) 'the generated server has no Resolve-PageLocale'
        # The template is written with backticked variables so they survive into
        # the generated text. One that lost its backtick expanded at generation
        # time and is now a constant, which reads correctly in the template.
        Assert-True ($text -match '\$AcceptLanguage') 'the parameter expanded away during generation'
        Assert-True ($text -match '\$supported') 'the supported set expanded away during generation'
        Assert-True ($text -match 'Read-TestConfig') `
            'the shipped resolver never reads the lab-wide language lock'
    }

    It 'answers each header the way every runtime here answers it' {
        $resolve = [scriptblock]::Create((Get-FunctionFromServer -Name 'Resolve-PageLocale') +
            "`nResolve-PageLocale -AcceptLanguage `$args[0] -ConfigLanguage ([string]`$args[1])")

        $cases = @(
            @{ Header = 'en-US';                     Tag = 'en-US'; Source = 'http';    Why = 'the ordinary case' }
            @{ Header = 'en'; Tag = 'en-US'; Requested = 'en'; Source = 'http'; Why = 'manifest aliases retain request provenance' }
            @{ Header = 'EN_us'; Tag = 'en-US'; Requested = 'en-US'; Source = 'http'; Why = 'underscore and case canonicalize once' }
            @{ Header = '';                          Tag = 'en-US'; Source = 'default'; Why = 'no preference takes the default' }
            @{ Header = 'de-DE';                     Tag = 'en-US'; Source = 'default'; Why = 'an unsupported language falls back' }
            @{ Header = '*';                         Tag = 'en-US'; Source = 'default'; Why = 'a bare wildcard expresses no preference' }
            @{ Header = 'de-DE;q=0.9, en-US;q=1.0';  Tag = 'en-US'; Source = 'http';    Why = 'weights decide, not document order' }
            @{ Header = 'en-US;q=0';                 Tag = 'en-US'; Source = 'default'; Why = 'refusing the only language served still yields it as the default' }
            @{ Header = 'qps-Ploc';                  Tag = 'en-US'; Source = 'default'; Why = 'a pseudo locale is not servable to a reader' }
            @{ Header = ('en-US,' * 200);            Tag = 'en-US'; Source = 'default'; Why = 'an oversized header is discarded whole' }
            @{ Header = 'en-US;q=banana';            Tag = 'en-US'; Source = 'default'; Why = 'a malformed weight rejects its candidate without aborting the parse' }
        )
        $findings = @()
        foreach ($case in $cases) {
            $got = & $resolve $case.Header
            $wantRequested = if ($case.ContainsKey('Requested')) { $case.Requested } else { $case.Tag }
            if ($got.Tag -ne $case.Tag) {
                $findings += "'$($case.Header)' resolved to $($got.Tag), want $($case.Tag) -- $($case.Why)"
            }
            if ($got.RequestedTag -ne $wantRequested -or $got.Source -ne $case.Source) {
                $findings += "'$($case.Header)' context was requested=$($got.RequestedTag), source=$($got.Source); want $wantRequested/$($case.Source)"
            }
        }
        Assert-NoFinding $findings 'the served language does not follow the shared rules'
    }

    It 'agrees with every shared request-only corpus case that resolves to its shipped default' {
        $resolve = [scriptblock]::Create((Get-FunctionFromServer -Name 'Resolve-PageLocale') +
            "`nResolve-PageLocale -AcceptLanguage `$args[0] -ConfigLanguage ([string]`$args[1])")
        $corpus = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
            (Join-Path $script:RepoRoot 'globalization/fixtures/locale-matching.json')))
        $findings = @()
        foreach ($case in @($corpus.cases)) {
            if ($case.userLanguage -or $case.processCulture -or $case.expect.resolvedTag -ne 'en-US') { continue }
            $header = [string]$case.acceptLanguage
            if ($case.acceptLanguageRepeat) {
                $header = [string]$case.acceptLanguageRepeat.unit * [int]$case.acceptLanguageRepeat.times
            }
            $got = & $resolve $header ([string]$case.configLanguage)
            $wantRequested = if ($case.expect.requestedTag) {
                [string]$case.expect.requestedTag
            } else { [string]$case.expect.resolvedTag }
            if ($got.Tag -ne $case.expect.resolvedTag -or $got.RequestedTag -ne $wantRequested -or
                $got.Source -ne $case.expect.source) {
                $findings += "$($case.name): got $($got.RequestedTag)/$($got.Tag)/$($got.Source), " +
                    "want $wantRequested/$($case.expect.resolvedTag)/$($case.expect.source)"
            }
        }
        Assert-NoFinding $findings 'the emitted status resolver drifted from the shared locale corpus'
    }

    It 'lets the config lock beat HTTP and treats AUTO as the unlocked sentinel' {
        $resolve = [scriptblock]::Create((Get-FunctionFromServer -Name 'Resolve-PageLocale') +
            "`nResolve-PageLocale -AcceptLanguage `$args[0] -ConfigLanguage ([string]`$args[1])")
        $prior = $env:YURUNA_ALLOW_PSEUDO_LOCALE
        try {
            $env:YURUNA_ALLOW_PSEUDO_LOCALE = '1'
            $locked = & $resolve 'qps-Ploc' 'en-US'
            Assert-StringEqual -Expected 'en-US' -Actual $locked.Tag `
                'Accept-Language overrode the lab-wide config lock'
            Assert-StringEqual -Expected 'config' -Actual $locked.Source `
                'the locked response did not retain config provenance'

            $automatic = & $resolve 'qps-Ploc' 'AUTO'
            Assert-StringEqual -Expected 'qps-Ploc' -Actual $automatic.Tag `
                'case-only AUTO became an unsupported config lock'
            Assert-StringEqual -Expected 'http' -Actual $automatic.Source `
                'the unlocked request did not retain HTTP provenance'
        } finally {
            $env:YURUNA_ALLOW_PSEUDO_LOCALE = $prior
        }
    }

    It 'opens the pseudo locales only when the run asks for them' {
        $resolve = [scriptblock]::Create((Get-FunctionFromServer -Name 'Resolve-PageLocale') +
            "`nResolve-PageLocale -AcceptLanguage `$args[0] -ConfigLanguage ([string]`$args[1])")

        $closed = & $resolve 'qps-Plocm'
        Assert-StringEqual -Expected 'en-US' -Actual $closed.Tag `
            'a release run served a pseudo locale, which a reader would take for a broken page'

        $prior = $env:YURUNA_ALLOW_PSEUDO_LOCALE
        try {
            $env:YURUNA_ALLOW_PSEUDO_LOCALE = 'false'
            $explicitFalse = & $resolve 'qps-Plocm'
            Assert-StringEqual -Expected 'en-US' -Actual $explicitFalse.Tag `
                'a templated false value accidentally enabled pseudo negotiation'

            $env:YURUNA_ALLOW_PSEUDO_LOCALE = '1'
            $open = & $resolve 'qps-Plocm'
            Assert-StringEqual -Expected 'qps-Plocm' -Actual $open.Tag 'a reference run cannot select the mirrored locale'
            Assert-StringEqual -Expected 'rtl' -Actual $open.Direction `
                'the mirrored locale did not report right-to-left, so a hard-coded direction would go unnoticed'
        } finally {
            $env:YURUNA_ALLOW_PSEUDO_LOCALE = $prior
        }
    }

    It 'rejects malformed q candidates and breaks equal weights by ordinal tag' {
        $resolve = [scriptblock]::Create((Get-FunctionFromServer -Name 'Resolve-PageLocale') +
            "`nResolve-PageLocale -AcceptLanguage `$args[0] -ConfigLanguage ([string]`$args[1])")
        $prior = $env:YURUNA_ALLOW_PSEUDO_LOCALE
        try {
            $env:YURUNA_ALLOW_PSEUDO_LOCALE = '1'
            $competitive = & $resolve 'qps-Plocm;q=banana, qps-Ploc;q=0.2'
            Assert-StringEqual -Expected 'qps-Ploc' -Actual $competitive.Tag `
                'the malformed candidate retained its initial q=1 and beat a valid lower weight'
            Assert-StringEqual -Expected 'http' -Actual $competitive.Source `
                'the valid lower-weight request was reported as a fallback'

            foreach ($header in @(
                'qps-Plocm;q, qps-Ploc;q=0.2'
                'qps-Plocm;q=0.1;q=1, qps-Ploc;q=0.2'
            )) {
                $strict = & $resolve $header
                Assert-StringEqual -Expected 'qps-Ploc' -Actual $strict.Tag `
                    "the malformed q parameter in '$header' remained eligible"
            }

            # qps-Plocm appears first deliberately. Header order must not decide
            # an equal weight; the shared contract sorts resolved tags ordinally.
            $equal = & $resolve 'qps-Plocm;q=0.5, qps-Ploc;q=0.5'
            Assert-StringEqual -Expected 'qps-Ploc' -Actual $equal.Tag `
                'equal weights retained header/hashtable order instead of the shared ordinal tie-break'
        } finally {
            $env:YURUNA_ALLOW_PSEUDO_LOCALE = $prior
        }
    }

    It 'loads the selected pseudo catalog from the shipped status directory' {
        $definitions = @(
            Get-FunctionFromServer -Name 'Get-RepresentationETag'
            Get-FunctionFromServer -Name 'Get-StatusLocaleCatalogAsset'
            Get-FunctionFromServer -Name 'Add-PageLocaleCatalog'
        )
        Assert-True (-not (@($definitions) -contains '')) `
            'the generated server has no content-addressed pseudo-catalog injection boundary'
        $inject = [scriptblock]::Create((@($definitions) -join "`n") +
            "`nAdd-PageLocaleCatalog -Html `$args[0] -Locale `$args[1] -CatalogRoot `$args[2]")
        $html = '<html lang="en"><body><script src="yuruna.common.js"></script></body></html>'
        $catalogRoot = Join-Path $script:RepoRoot 'test/status'

        $english = [string](& $inject $html 'en-US' $catalogRoot)
        Assert-StringEqual -Expected $html -Actual $english 'the default language gained an unnecessary request'

        foreach ($tag in 'qps-Ploc', 'qps-Plocm') {
            $pseudo = [string](& $inject $html $tag $catalogRoot)
            Assert-True ($pseudo -match ('<script src="/' + [regex]::Escape($tag) +
                    '\.[0-9a-f]{64}\.status\.js"></script>')) `
                "the $tag catalog was not loaded through a content-addressed URL"
            Assert-True ($pseudo.IndexOf('yuruna.common.js') -lt $pseudo.IndexOf("$tag.")) `
                'the catalog must load after the runtime and before its ready callback fires'
        }
    }

    It 'does not inject the status runtime into nested transcript HTML' {
        $definitions = @(
            Get-FunctionFromServer -Name 'Get-RepresentationETag'
            Get-FunctionFromServer -Name 'Get-StatusLocaleCatalogAsset'
            Get-FunctionFromServer -Name 'Add-PageLocaleCatalog'
        )
        $inject = [scriptblock]::Create((@($definitions) -join "`n") +
            "`nAdd-PageLocaleCatalog -Html `$args[0] -Locale qps-Ploc -CatalogRoot `$args[1]")
        $transcript = '<html lang="en"><body><pre>persisted cycle output</pre></body></html>'
        $actual = [string](& $inject $transcript (Join-Path $script:RepoRoot 'test/status'))
        Assert-StringEqual -Expected $transcript -Actual $actual `
            'a pseudo request changed or aborted a non-status HTML report with no runtime marker'
    }

    It 'serves a hash-matched pseudo catalog as immutable and retains its validator on 304' {
        $definitions = @(
            Get-FunctionFromServer -Name 'Get-RepresentationETag'
            Get-FunctionFromServer -Name 'Get-StatusLocaleCatalogAsset'
            Get-FunctionFromServer -Name 'Test-RepresentationETagMatch'
            Get-FunctionFromServer -Name 'Set-ImmutableAssetValidator'
        )
        Assert-True (-not (@($definitions) -contains '')) `
            'the generated server lost an immutable catalog helper'
        $harness = [scriptblock]::Create((@($definitions) -join "`n") + @'

$asset = Get-StatusLocaleCatalogAsset -Locale ([string]$args[0]) -Root ([string]$args[1])
$requestHeaders = [System.Net.WebHeaderCollection]::new()
if ($args[2]) { $requestHeaders.Set('If-None-Match', [string]$args[2]) }
$responseHeaders = [System.Net.WebHeaderCollection]::new()
$request = [pscustomobject]@{ Headers = $requestHeaders }
$response = [pscustomobject]@{ Headers = $responseHeaders; StatusCode = 200 }
$shouldWrite = Set-ImmutableAssetValidator -Request $request -Response $response -Asset $asset
[pscustomobject]@{
    Asset = $asset
    ShouldWrite = [bool]$shouldWrite
    StatusCode = [int]$response.StatusCode
    CacheControl = [string]$response.Headers['Cache-Control']
    ETag = [string]$response.Headers['ETag']
}
'@)
        $root = Join-Path $script:RepoRoot 'test/status'
        $first = & $harness 'qps-Plocm' $root ''
        Assert-True ($first.Asset.RequestName -cmatch '^qps-Plocm\.[0-9a-f]{64}\.status\.js$') `
            'the status catalog request name does not carry its full SHA-256'
        Assert-StringEqual -Expected $first.Asset.ETag -Actual ('"' +
            (($first.Asset.RequestName -split '\.')[1]) + '"') `
            'the URL content hash and the asset ETag differ'
        Assert-StringEqual -Expected 'public,max-age=31536000,immutable' -Actual $first.CacheControl `
            'the content-addressed status catalog is not immutable'
        Assert-True $first.ShouldWrite 'a first request incorrectly suppressed the catalog body'

        $matching = & $harness 'qps-Plocm' $root $first.ETag
        Assert-False $matching.ShouldWrite 'a matching status catalog validator did not suppress the body'
        Assert-Equal -Expected 304 -Actual $matching.StatusCode 'a matching status catalog did not return 304'
        Assert-StringEqual -Expected $first.ETag -Actual $matching.ETag 'the status catalog 304 dropped its ETag'
        Assert-StringEqual -Expected 'public,max-age=31536000,immutable' -Actual $matching.CacheControl `
            'the status catalog 304 dropped immutable caching'

        Assert-True ($script:ServerText.Contains(
                "-cmatch '^(qps-Ploc|qps-Plocm)\.([0-9a-f]{64})\.status\.js$'")) `
            'the shipped route does not require an exact hash-qualified catalog name'
        Assert-True ($script:ServerText.Contains('$rel -ceq $candidateCatalog.RequestName')) `
            'the shipped route can serve catalog bytes under a made-up hash'
    }

    It 'serves the bytes captured with the immutable URL even if the stable file is replaced' {
        $definitions = @(
            Get-FunctionFromServer -Name 'Get-RepresentationETag'
            Get-FunctionFromServer -Name 'Get-StatusLocaleCatalogAsset'
        )
        $capture = [scriptblock]::Create((@($definitions) -join "`n") +
            "`nGet-StatusLocaleCatalogAsset -Locale qps-Ploc -Root `$args[0]")
        $root = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-status-catalog-race-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        try {
            $path = Join-Path $root 'qps-Ploc.status.js'
            $original = [Text.Encoding]::UTF8.GetBytes('window.originalCatalog = true;')
            $replacement = [Text.Encoding]::UTF8.GetBytes('window.replacementCatalog = true;')
            [IO.File]::WriteAllBytes($path, $original)
            $asset = & $capture $root
            [IO.File]::WriteAllBytes($path, $replacement)

            Assert-StringEqual -Expected 'window.originalCatalog = true;' `
                -Actual ([Text.Encoding]::UTF8.GetString($asset.Bytes)) `
                'the immutable asset did not retain the bytes its URL hashed'
            Assert-StringEqual -Expected 'window.replacementCatalog = true;' `
                -Actual ([IO.File]::ReadAllText($path)) 'the race fixture did not replace the stable source'
            Assert-True ($script:ServerText.Contains(
                    '[byte[]]$immutableLocaleCatalog.Bytes')) `
                'the shipped route re-reads the replaceable stable source after validating its hash'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ships byte-identical copies of both generated status pseudo catalogs' {
        foreach ($tag in 'qps-Ploc', 'qps-Plocm') {
            $generated = Join-Path $script:RepoRoot "globalization/generated/browser/$tag.status.js"
            $shipped = Join-Path $script:RepoRoot "test/status/$tag.status.js"
            Assert-True (Test-Path -LiteralPath $shipped -PathType Leaf) "the shipped $tag status catalog is missing"
            $want = (([IO.File]::ReadAllText($generated)) -replace "`r`n", "`n").TrimEnd()
            $got = (([IO.File]::ReadAllText($shipped)) -replace "`r`n", "`n").TrimEnd()
            Assert-StringEqual -Expected $want -Actual $got "the shipped $tag status catalog is stale"
        }
    }

    It 'labels the generated listing as well as the files it serves' {
        # The directory index is built in the server rather than read off disk,
        # so it is the page most likely to be forgotten -- and it is the one an
        # operator lands on when they are already looking for something.
        #
        # Plain substring checks: the generated text is PowerShell source full
        # of quotes and dollars, and a regex over it is mostly escaping.
        Assert-True ($script:ServerText.Contains('$listingLocale = Resolve-PageLocale')) `
            'the generated listing does not resolve a language'
        Assert-True ($script:ServerText.Contains('<html lang="'' + $listingTagEnc')) `
            'the generated listing does not carry the resolved language'
        Assert-True ($script:ServerText.Contains('data-yuruna-requested-language="'' + $listingRequestedEnc')) `
            'the generated listing does not carry the request winner'
        Assert-True ($script:ServerText.Contains('data-yuruna-locale-source="'' + $listingSourceEnc')) `
            'the generated listing does not carry the selection source'
        Assert-True ($script:ServerText.Contains(
                'Set-LocalizedRepresentationValidator -Request $req -Response $res')) `
            'the generated listing does not pass its final bytes through the localized response validator'
    }

    It 'renders the shipped listing and error path in pseudo identically under six host cultures' {
        $block = Get-DirectoryListingBlockFromServer
        Assert-False ($block.Contains('{0:N1}')) `
            'the shipped listing still delegates numeric punctuation to the host culture'
        $builder = [scriptblock]::Create($block + "`n`$sb.ToString()")
        $directory = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-status-listing-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory
        try {
            [IO.File]::WriteAllBytes((Join-Path $directory 'sample.bin'), [byte[]]::new(1536))
            $entries = @(Get-ChildItem -LiteralPath $directory)
            $outputs = @()
            $originalCulture = [Globalization.CultureInfo]::CurrentCulture
            $originalUiCulture = [Globalization.CultureInfo]::CurrentUICulture
            try {
                foreach ($cultureName in @('en-US', 'pt-BR', 'de-DE', 'tr-TR', 'th-TH', 'ar-SA')) {
                    $culture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                    [Globalization.CultureInfo]::CurrentCulture = $culture
                    [Globalization.CultureInfo]::CurrentUICulture = $culture
                    $rendered = $builder.InvokeWithContext(@{}, @(
                            [psvariable]::new('entries', $entries)
                            [psvariable]::new('origLocal', '/log/a-cycle/')
                            [psvariable]::new('listingLocale', @{
                                    Tag = 'qps-Plocm'; RequestedTag = 'qps-Plocm'
                                    Direction = 'rtl'; Source = 'http'
                                })
                        )) -join ''
                    $outputs += $rendered
                }
            } finally {
                [Globalization.CultureInfo]::CurrentCulture = $originalCulture
                [Globalization.CultureInfo]::CurrentUICulture = $originalUiCulture
            }

            foreach ($output in $outputs) {
                Assert-StringEqual -Expected $outputs[0] -Actual $output `
                    'the emitted listing changed with the status-service host culture'
                Assert-True ($output.Contains('<html lang="qps-Plocm" dir="rtl"')) `
                    'the pseudo listing lost its locale or direction'
                foreach ($english in @('Index of ', 'Contents of ', '>Name<', '>Size<', 'Modified (UTC)', 'Parent directory')) {
                    Assert-False ($output.Contains($english)) `
                        "the pseudo listing retained the English literal '$english'"
                }
                Assert-True ($output.Contains('data-bytes="1536"')) `
                    'the exact invariant byte count was lost from the machine-only size attribute'
                Assert-False ($output.Contains('title="1536 bytes"')) `
                    'the user-visible exact-size title remained English in pseudo'
            }

            foreach ($key in @('status.error_file_too_large', 'status.error_not_found')) {
                $pseudo = Format-CatalogMessage -Key $key -Locale 'qps-Plocm'
                Assert-False ($pseudo -eq $(if ($key -eq 'status.error_not_found') { 'Not found' } else { 'File too large' })) `
                    "$key did not render through the pseudo catalog"
                Assert-True ($script:ServerText.Contains("-Key '$key'")) `
                    "$key is not used by the shipped error route"
            }
            Assert-True (([regex]::Matches($script:ServerText,
                        'Set-StatusErrorRepresentation -Request \$req -Response \$res')).Count -eq 2) `
                'the generated 413 and 404 paths do not share the localized error response boundary'
        } finally {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'HTML-encodes translator-owned file-size wording in the shipped listing builder' {
        $block = Get-DirectoryListingBlockFromServer
        $builder = [scriptblock]::Create($block + "`n`$sb.ToString()")
        $directory = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-status-listing-hostile-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory
        try {
            [IO.File]::WriteAllBytes((Join-Path $directory 'sample.bin'), [byte[]]::new(1536))
            $functions = @{
                'Format-CatalogNumber' = { param($Value, $Locale, $Decimals) $null = $Value, $Locale, $Decimals; '1.5' }
                'Format-CatalogMessage' = {
                    param($Key, $Arguments, $Locale)
                    $null = $Arguments, $Locale
                    if ($Key -in @('status.file_size_kilobytes', 'status.file_size_bytes')) {
                        return '<img src=x onerror=alert(1)>'
                    }
                    return $Key
                }
            }
            $rendered = $builder.InvokeWithContext($functions, @(
                    [psvariable]::new('entries', @(Get-ChildItem -LiteralPath $directory))
                    [psvariable]::new('origLocal', '/log/a-cycle/')
                    [psvariable]::new('listingLocale', @{
                            Tag = 'en-US'; RequestedTag = 'en-US'; Direction = 'ltr'; Source = 'http'
                        })
                )) -join ''
            Assert-False ($rendered.Contains('<img src=x onerror=alert(1)>')) `
                'translator-owned size wording became executable listing markup'
            Assert-True ($rendered.Contains('&lt;img src=x onerror=alert(1)&gt;')) `
                'translator-owned size wording was lost rather than encoded as text'
            Assert-True ($rendered.Contains('data-bytes="1536"')) `
                'encoding localized display text changed the invariant machine byte value'
        } finally {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'strips injected bidi controls and isolates displayed listing paths and names' {
        $block = Get-DirectoryListingBlockFromServer
        $builder = [scriptblock]::Create($block + "`n`$sb.ToString()")
        $directory = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-status-listing-bidi-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory
        $pdi = [char]0x2069
        $override = [char]0x202e
        $rawName = 'sample' + $pdi + $override + '.bin'
        try {
            [IO.File]::WriteAllBytes((Join-Path $directory $rawName), [byte[]]::new(1))
            $rawPath = '/log/' + $pdi + $override + 'cycle/'
            $rendered = $builder.InvokeWithContext(@{}, @(
                    [psvariable]::new('entries', @(Get-ChildItem -LiteralPath $directory))
                    [psvariable]::new('origLocal', $rawPath)
                    [psvariable]::new('listingLocale', @{
                            Tag = 'en-US'; RequestedTag = 'en-US'; Direction = 'ltr'; Source = 'http'
                        })
                )) -join ''
            $start = [char]0x2068
            $end = [char]0x2069
            Assert-False ($rendered.Contains($override)) `
                'an attacker-controlled bidi override survived in listing markup'
            Assert-True ($rendered.Contains('Index of ' + $start + '/log/cycle/' + $end)) `
                'the displayed directory path was not stripped and isolated'
            Assert-True ($rendered.Contains('>' + $start + 'sample.bin' + $end + '</a>')) `
                'the displayed entry name was not stripped and isolated'
            $escapedRawName = [Uri]::EscapeDataString($rawName)
            Assert-True ($rendered.Contains('href="' + $escapedRawName + '"')) `
                'the safe displayed name replaced the independently percent-encoded href target'
        } finally {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits localized error metadata without hiding 404 or 413 behind a 304' {
        $definitions = @(
            Get-FunctionFromServer -Name 'Get-RepresentationETag'
            Get-FunctionFromServer -Name 'Test-RepresentationETagMatch'
            Get-FunctionFromServer -Name 'Set-ResponseLocaleHeaders'
            Get-FunctionFromServer -Name 'Set-LocalizedRepresentationValidator'
            Get-FunctionFromServer -Name 'Set-StatusErrorRepresentation'
        )
        Assert-True (-not (@($definitions) -contains '')) 'the emitted error response helper is incomplete'
        $harness = [scriptblock]::Create((@($definitions) -join "`n") + @'

$requestHeaders = [System.Net.WebHeaderCollection]::new()
if ($args[0]) { $requestHeaders.Set('If-None-Match', [string]$args[0]) }
$responseHeaders = [System.Net.WebHeaderCollection]::new()
$request = [pscustomobject]@{ Headers = $requestHeaders }
$response = [pscustomobject]@{
    Headers = $responseHeaders
    StatusCode = 200
    ContentType = ''
    ContentLength64 = [long]-1
}
$locale = @{ Tag = 'qps-Plocm' }
$result = Set-StatusErrorRepresentation -Request $request -Response $response -StatusCode ([int]$args[1]) -Key ([string]$args[2]) -Locale $locale
[pscustomobject]@{
    Result = $result
    StatusCode = [int]$response.StatusCode
    ContentType = [string]$response.ContentType
    ContentLength64 = [long]$response.ContentLength64
    CacheControl = [string]$response.Headers['Cache-Control']
    ContentLanguage = [string]$response.Headers['Content-Language']
    Vary = (@($response.Headers.GetValues('Vary')) -join ',')
    ETag = [string]$response.Headers['ETag']
}
'@)
        $first = & $harness '' 404 'status.error_not_found'
        Assert-Equal -Expected 404 -Actual $first.StatusCode 'the localized error lost its HTTP status'
        Assert-StringEqual -Expected 'text/plain; charset=utf-8' -Actual $first.ContentType `
            'the localized error inherited the requested file content type'
        Assert-StringEqual -Expected 'no-store' -Actual $first.CacheControl `
            'the localized error became cacheable as a live status response'
        Assert-StringEqual -Expected 'qps-Plocm' -Actual $first.ContentLanguage `
            'the localized error did not identify its language'
        Assert-True ($first.Vary -match '(?i)(?:^|,)\s*Accept-Language\s*(?:,|$)') `
            'the localized error did not vary on its negotiation input'
        Assert-True ($first.ETag -match '^"[0-9a-f]{64}"$') 'the localized error has no body validator'
        Assert-Equal -Expected $first.Result.Bytes.Length -Actual $first.ContentLength64 `
            'the localized error Content-Length does not describe its UTF-8 body'
        Assert-False ([Text.Encoding]::UTF8.GetString($first.Result.Bytes) -eq 'Not found') `
            'the error path bypassed the pseudo catalog'

        $matching = & $harness $first.ETag 404 'status.error_not_found'
        Assert-Equal -Expected 404 -Actual $matching.StatusCode `
            'a matching validator hid a real not-found response behind 304'
        Assert-True $matching.Result.ShouldWrite 'a conditional request suppressed the not-found detail body'
        Assert-Equal -Expected $matching.Result.Bytes.Length -Actual $matching.ContentLength64 `
            'the conditional not-found response lost its body length'

        $tooLarge = & $harness '' 413 'status.error_file_too_large'
        $matchingTooLarge = & $harness $tooLarge.ETag 413 'status.error_file_too_large'
        Assert-Equal -Expected 413 -Actual $matchingTooLarge.StatusCode `
            'a matching validator hid a real file-too-large response behind 304'
        Assert-True $matchingTooLarge.Result.ShouldWrite 'a conditional request suppressed the file-too-large detail body'
        Assert-StringEqual -Expected 'qps-Plocm' -Actual $matchingTooLarge.ContentLanguage `
            'the conditional file-too-large response lost its language metadata'
        Assert-StringEqual -Expected 'text/plain; charset=utf-8' -Actual $matching.ContentType `
            'the conditional error dropped its representation content type'
        Assert-StringEqual -Expected 'qps-Plocm' -Actual $matching.ContentLanguage `
            'the conditional error dropped Content-Language'
        Assert-StringEqual -Expected $first.ETag -Actual $matching.ETag 'the conditional error dropped its ETag'
    }

    It 'writes the language into the document and onto the response' {
        # Lift the transform out of the generated server, including its catalog
        # dependency, and run it against a real shipped page. Reading the
        # launcher template would miss an interpolation bug in the emitted code.
        $etag = Get-FunctionFromServer -Name 'Get-RepresentationETag'
        $asset = Get-FunctionFromServer -Name 'Get-StatusLocaleCatalogAsset'
        $add = Get-FunctionFromServer -Name 'Add-PageLocaleCatalog'
        $convert = Get-FunctionFromServer -Name 'ConvertTo-LocalizedPageHtml'
        Assert-True ([bool]$etag) 'the generated server has no catalog hash helper'
        Assert-True ([bool]$asset) 'the generated server has no catalog asset helper'
        Assert-True ([bool]$add) 'the generated server has no catalog injection function'
        Assert-True ([bool]$convert) 'the generated server has no localized representation function'
        Assert-True ($convert -match 'HtmlEncode') 'locale context fields are inserted without attribute escaping'
        $render = [scriptblock]::Create($etag + "`n" + $asset + "`n" + $add + "`n" + $convert +
            "`nConvertTo-LocalizedPageHtml -Html `$args[0] -Locale `$args[1] -CatalogRoot `$args[2]")

        # And the replacement actually matches what the pages carry.
        $findings = @()
        foreach ($page in (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test/status') -Filter '*.html' -File)) {
            $html = [IO.File]::ReadAllText($page.FullName)
            if ($html -notmatch '<html lang="en">') {
                $findings += "$($page.Name) does not carry the tag the server rewrites, so it would ship unlabeled"
            }
        }
        Assert-NoFinding $findings 'a status page would be served without a resolved language'

        # Rendered end to end, on the real markup.
        $sample = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'test/status/index.html'))
        $locale = @{
            Tag = 'qps-Plocm'; RequestedTag = 'qps-Plocm'; Direction = 'rtl'; Source = 'http'
        }
        $rewritten = [string](& $render $sample $locale (Join-Path $script:RepoRoot 'test/status'))
        Assert-True ($rewritten -match '<html lang="qps-Plocm" dir="rtl" data-yuruna-requested-language="qps-Plocm" data-yuruna-locale-source="http">') 'the rewrite does not apply to the shipped page'
        Assert-True ($rewritten -notmatch '<html lang="en">') 'the original tag survived the rewrite'
        Assert-True ($rewritten -match '<script src="/qps-Plocm\.[0-9a-f]{64}\.status\.js"></script>') `
            'the final mirrored representation does not load its catalog'
    }

    It 'validates the final localized bytes and keeps locale headers on 304' {
        $definitions = @(
            Get-FunctionFromServer -Name 'Get-RepresentationETag'
            Get-FunctionFromServer -Name 'Test-RepresentationETagMatch'
            Get-FunctionFromServer -Name 'Set-ResponseLocaleHeaders'
            Get-FunctionFromServer -Name 'Set-LocalizedRepresentationValidator'
        )
        Assert-True (-not (@($definitions) -contains '')) 'the generated server lost an ETag helper'

        # A small in-memory response exercises the exact generated helper. The
        # first pass captures each representation's strong validator; the next
        # two model a cache presenting the wrong and right locale validators.
        $harness = [scriptblock]::Create((@($definitions) -join "`n") + @'

$requestHeaders = [System.Net.WebHeaderCollection]::new()
if ($args[2]) { $requestHeaders.Set('If-None-Match', [string]$args[2]) }
$responseHeaders = [System.Net.WebHeaderCollection]::new()
$request = [pscustomobject]@{ Headers = $requestHeaders }
$response = [pscustomobject]@{
    Headers = $responseHeaders
    StatusCode = 200
    ContentLength64 = [long]-1
}
$bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$args[0])
$locale = @{ Tag = [string]$args[1] }
$shouldWrite = Set-LocalizedRepresentationValidator -Request $request -Response $response -Bytes $bytes -Locale $locale
[pscustomobject]@{
    ShouldWrite = [bool]$shouldWrite
    StatusCode = [int]$response.StatusCode
    ContentLength64 = [long]$response.ContentLength64
    ContentLanguage = [string]$response.Headers['Content-Language']
    Vary = (@($response.Headers.GetValues('Vary')) -join ',')
    ETag = [string]$response.Headers['ETag']
}
'@)
        $english = & $harness '<html lang="en-US">English</html>' 'en-US' ''
        $mirrored = & $harness '<html lang="qps-Plocm" dir="rtl">Mirrored</html>' 'qps-Plocm' ''
        Assert-True ($english.ETag -match '^"[0-9a-f]{64}"$') 'the representation has no strong SHA-256 ETag'
        Assert-True ($english.ETag -cne $mirrored.ETag) `
            'different localized bytes share a validator, so a cache can suppress the wrong language'

        $wrongLocale = & $harness '<html lang="qps-Plocm" dir="rtl">Mirrored</html>' `
            'qps-Plocm' $english.ETag
        Assert-True $wrongLocale.ShouldWrite 'an English validator falsely returned 304 for mirrored bytes'
        Assert-Equal -Expected 200 -Actual $wrongLocale.StatusCode 'the wrong-locale request was marked not modified'

        $matching = & $harness '<html lang="qps-Plocm" dir="rtl">Mirrored</html>' `
            'qps-Plocm' ('"unrelated", W/' + $mirrored.ETag)
        Assert-False $matching.ShouldWrite 'a matching weak/list validator did not suppress the body'
        Assert-Equal -Expected 304 -Actual $matching.StatusCode 'a matching validator did not return not modified'
        Assert-Equal -Expected -1 -Actual $matching.ContentLength64 `
            'a 304 emitted a false Content-Length instead of leaving it unset'
        Assert-StringEqual -Expected 'qps-Plocm' -Actual $matching.ContentLanguage `
            'the 304 dropped the language of the representation that matched'
        Assert-True ($matching.Vary -match '(?i)(?:^|,)\s*Accept-Language\s*(?:,|$)') `
            'the 304 dropped Vary: Accept-Language and became unsafe for a shared cache'
        Assert-StringEqual -Expected $mirrored.ETag -Actual $matching.ETag `
            'the 304 did not return the validator that matched'

        Assert-True (([regex]::Matches($script:ServerText,
                    'Set-LocalizedRepresentationValidator -Request \$req -Response \$res')).Count -ge 2) `
            'both generated directory and file representations must use the validated response path'
    }
}

Describe 'the server comes up holding the commands its pages call' {

    It 'keeps every page-rendering command resolvable after replaying its own startup imports' {
        # Replayed in a child rather than asserted about here, because the
        # thing that can go wrong is not visible in this runspace: an import
        # that re-homes a module into a private scope both succeeds and writes
        # nothing to any stream, and this suite already holds those modules by
        # a different route. Only a runspace that starts empty and runs the
        # server's own statements, in the server's own order, answers the
        # question the server asks -- which is whether the commands are there
        # when the first request arrives.
        $pwshPath = (Get-Process -Id $PID).Path
        if (-not $pwshPath) { $pwshPath = 'pwsh' }
        if (-not (Get-Command -Name $pwshPath -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'no pwsh executable on this host to open a fresh runspace with'
            return
        }

        Assert-True ($script:ServerPrologueImport.Count -gt 0) `
            'no startup imports were found above the first function of the generated server'
        Assert-True ($script:RequiredServerCommand.Count -gt 0) `
            'no required command was derived, so replaying the imports would assert nothing'

        $quotedCommand = @($script:RequiredServerCommand |
                ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
        $replayLines = @(
            "`$ErrorActionPreference = 'Stop'"
            # The launcher bakes its own machine's checkout into this
            # assignment; rebinding it is what lets the replay resolve the
            # same modules anywhere the suite runs.
            ("`$repoRoot = '" + ($script:RepoRoot -replace "'", "''") + "'")
        ) + @($script:ServerPrologueImport | ForEach-Object { $_.Text }) + @(
            "`$required = @($quotedCommand)"
            @'
foreach ($name in $required) {
    $command = Get-Command -Name $name -ErrorAction SilentlyContinue
    Write-Output ('YURUNA-RESOLVED ' + (ConvertTo-Json -Compress -InputObject ([ordered]@{
                    command  = $name
                    resolved = [bool]$command
                    module   = [string]$(if ($command) { $command.ModuleName })
                })))
}
'@
        )

        $sandbox = Join-Path ([IO.Path]::GetTempPath()) (
            'yuruna-status-import-replay-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox
        try {
            $replayPath = Join-Path $sandbox 'replay-server-imports.ps1'
            [IO.File]::WriteAllText($replayPath, (($replayLines -join "`n") + "`n"))
            $output = & $pwshPath -NoProfile -File $replayPath 2>&1 | Out-String
            $exitCode = $LASTEXITCODE

            $reported = @{}
            foreach ($line in ($output -split "`r?`n")) {
                if ($line -notmatch '^YURUNA-RESOLVED (\{.+\})$') { continue }
                $record = ConvertFrom-Json -InputObject $Matches[1]
                $reported[[string]$record.command] = $record
            }

            $findings = @()
            if ($exitCode -ne 0) {
                $findings += "the startup imports did not run to completion (exit $exitCode): $($output.Trim())"
            }
            foreach ($name in $script:RequiredServerCommand) {
                if (-not $reported.ContainsKey($name)) {
                    $findings += "$name was never probed, so the replay stopped before reaching it"
                    continue
                }
                if (-not $reported[$name].resolved) {
                    $findings += ("$name is exported by $($script:PrologueExport[$name]) and does not " +
                        'resolve once the startup imports have run in their own order')
                }
            }
            Assert-NoFinding $findings ('a localizing route would throw on every request in a runspace ' +
                'that ran the status service startup imports')
        } finally {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'derives that command set from what the emitted server calls rather than from a list' {
        # The derivation is what keeps the replay honest as routes change, and
        # a derivation that quietly returns nothing still passes. These five
        # are reached by both selection rules -- the resolver reads the config
        # pair and the manifest pair, the error and listing paths render
        # through the catalog -- so their absence means the scan stopped
        # finding call sites, not that the server stopped needing them.
        $findings = @()
        foreach ($name in @('Get-LocaleManifest', 'New-LocaleContext', 'Format-CatalogMessage',
                'Read-TestConfig', 'Get-TestConfigValue')) {
            if ($script:RequiredServerCommand -notcontains $name) {
                $findings += "$name is called by the generated server but was not derived as required"
            }
        }
        Assert-NoFinding $findings `
            'the required-command scan no longer sees the commands the localized pages are built from'
    }

    It 'names every module command it calls in the exports of a module it loads' {
        # Static twin of the replay: a rename or a dropped Export-ModuleMember
        # leaves the server calling a name nothing publishes, and that costs a
        # process to notice behaviorally. The scan is confined to commands some
        # module here owns, so a native tool, a platform cmdlet and a command
        # an extension supplies at run time all fall out on their own and the
        # result does not depend on what a given host has installed.
        $findings = @()
        foreach ($import in $script:ServerPrologueImport) {
            if (-not $import.Module) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot $import.Module) -PathType Leaf)) {
                $findings += "$($import.Module) is imported at startup but no such module ships"
            }
        }
        foreach ($name in $script:ServerModuleCall) {
            if ($script:PrologueExport.ContainsKey($name)) { continue }
            if ($script:RouteGuardedCommand.ContainsKey($name)) { continue }
            $findings += ("$name is exported by $($script:RepoModuleExport[$name] -join ', ') -- " +
                'a module the server neither imports at startup nor loads through its route guard')
        }

        # The scan above starts from the modules, so a command renamed on both
        # sides at once leaves it with nothing to notice. This one starts from
        # the call site instead: whatever the locale resolver invokes has to be
        # published by a startup module, and a rename that reached only the
        # module leaves the name here pointing at nothing. PowerShell's own
        # cmdlets are the only other thing that function calls.
        foreach ($name in @($script:LocaleResolverCall | Sort-Object -Unique)) {
            if ($script:ServerDefinedFunction.ContainsKey($name)) { continue }
            if (Get-Command -Name $name -CommandType Cmdlet -ErrorAction SilentlyContinue) { continue }
            if ($script:PrologueExport.ContainsKey($name)) { continue }
            $findings += ("the locale resolver calls $name, which no module the server imports " +
                'at startup publishes')
        }
        Assert-NoFinding $findings `
            'the generated server calls a module command nothing it loads publishes'
    }
}

Describe 'a request that throws leaves something to read' {

    It 'records the throw before it tears the connection down' {
        # Aborting is the honest answer once a handler has failed mid-response,
        # but it reaches the client as a bare torn connection whose shape is
        # decided by the listener rather than by the fault: a reset under
        # http.sys, an empty chunked 200 under the managed listener. Neither
        # carries a reason. Without a line written before the abort, a route
        # that fails on every request and a host that has lost the network are
        # the same observation, and the search starts in the wrong place.
        $clause = Get-AbortingCatchFromServer -ContextVariable '$ctx'
        $logged = @($clause.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Write-ServerErr'
                }, $true))
        $aborted = @($clause.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Member.Value -eq 'Abort'
                }, $true))

        Assert-Equal -Expected 1 -Actual $logged.Count `
            'the per-request catch does not write exactly one server-error line'
        Assert-Equal -Expected 1 -Actual $aborted.Count `
            'the per-request catch aborts the response more than once'
        Assert-True ($logged[0].Extent.StartOffset -lt $aborted[0].Extent.StartOffset) `
            'the abort runs before the line that explains it, so a throw inside the abort loses the reason'

        $line = $logged[0].Extent.Text
        Assert-Match -Pattern '\$path' -Actual $line `
            'the logged line does not say which path failed'
        Assert-Match -Pattern '\$_\.Exception\.GetType\(\)\.FullName' -Actual $line `
            'the logged line does not name the exception type'
        Assert-Match -Pattern '\$_\.Exception\.Message' -Actual $line `
            'the logged line does not carry the exception message'
    }

    It 'records the throw before it tears down a git archive response' {
        # Same trap, a second receiver: this one streams a packed folder and
        # holds its context in a parameter of its own, so it is a separate
        # abort site that can lose its reason independently.
        $clause = Get-AbortingCatchFromServer -ContextVariable '$Context'
        $logged = @($clause.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Write-ServerErr'
                }, $true))
        $aborted = @($clause.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Member.Value -eq 'Abort'
                }, $true))

        Assert-Equal -Expected 1 -Actual $logged.Count `
            'the archive streamer does not write exactly one server-error line before aborting'
        Assert-True ($logged[0].Extent.StartOffset -lt $aborted[0].Extent.StartOffset) `
            'the archive stream aborts before the line that explains it'
        Assert-Match -Pattern '\$_\.Exception\.Message' -Actual $logged[0].Extent.Text `
            'the archive stream abort carries no exception message'
    }
}
