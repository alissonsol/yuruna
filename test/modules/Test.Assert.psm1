<#PSScriptInfo
.VERSION 2026.11.05
.GUID 423d6743-1531-4ed7-b6b3-7d5bf06035c0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester assert scaffold
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
    One assertion vocabulary and one set of test scaffolds for every Pester
    suite in the repo.
.DESCRIPTION
    296 hand-rolled Assert-* definitions across 151 of 182 suites is the tax on
    every behavioral test the harness wants next, and it compounds: the count
    was 234 when it was first measured, because each new suite copies the
    helpers from a neighbor. This module is the one place they live.

    WHY Assert-Equal AND Assert-StringEqual ARE SEPARATE EXPORTS. The suites had
    drifted into three incompatible semantics for one name:

      * 91 suites compared by value      -- `$Expected -ne $Actual`
      * 14 suites compared string-coerced -- `"$Expected" -ne "$Actual"`
      *  4 suites additionally inverted the parameter order, so a positional
        call meant the opposite of what it meant everywhere else

    The two semantics are NOT separated by type strictness, which is the
    intuitive but wrong reading: `1 -ne '1'` is false, because PowerShell
    coerces the right operand to the left operand's type, so both forms accept
    it. Measured, they diverge in exactly these ways -- leading zeros,
    surrounding whitespace and float rendering (`1` vs `'01'`, `1.0` vs
    `'1.0'`) are equal by value and different as strings; `$null` against an
    empty string is the reverse; and, sharpest of all, `-ne` on ARRAYS filters
    element-wise rather than comparing, so value comparison REJECTS two
    identical arrays that string comparison accepts.

    That array behavior is why the coercing callers move to Assert-StringEqual
    rather than being folded into Assert-Equal: a suite comparing two collections
    through the coercing helper passes today and would begin failing under value
    semantics, for a reason that has nothing to do with the code under test.

    Parameter ALIASES carry the historical spellings (-Value for -Actual,
    -Expected for -NotExpected, -Action for -Script, -Findings for -Finding).
    That is deliberate: it lets ~2,800 existing call sites keep working
    untouched, so the migration is "delete the local copy, import this" rather
    than a rewrite of every assertion in the repo.

    Assertions throw rather than using Pester's Should. The suites were written
    that way so they also run as plain scripts, and preserving it keeps the
    migration behavior-preserving.
#>

Set-StrictMode -Version Latest

# --- REGION: Assertions
function Assert-True {
    <#
    .SYNOPSIS
    Fails unless the condition is truthy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Condition,
        [Parameter(Position = 1)][string]$Because = ''
    )
    if (-not $Condition) { throw "Expected true. $Because" }
}

function Assert-False {
    <#
    .SYNOPSIS
    Fails unless the condition is falsy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Condition,
        [Parameter(Position = 1)][string]$Because = ''
    )
    if ($Condition) { throw "Expected false. $Because" }
}

function Assert-Equal {
    <#
    .SYNOPSIS
    Fails unless the two values are equal BY VALUE. Use Assert-StringEqual when
    the comparison is deliberately between string renderings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Expected,
        [Parameter(Position = 1)]$Actual,
        [Parameter(Position = 2)][string]$Because = ''
    )
    if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" }
}

function Assert-StringEqual {
    <#
    .SYNOPSIS
    Fails unless the two values render to the same string. Distinct from
    Assert-Equal so that a deliberate coercion is visible at the call site
    rather than hidden in a local helper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Expected,
        [Parameter(Position = 1)]$Actual,
        [Parameter(Position = 2)][string]$Because = ''
    )
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

function Assert-NotEqual {
    <#
    .SYNOPSIS
    Fails when the two values are equal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('Expected')]$NotExpected,
        [Parameter(Position = 1)]$Actual,
        [Parameter(Position = 2)][string]$Because = ''
    )
    if ($NotExpected -eq $Actual) { throw "Expected NOT [$NotExpected]. $Because" }
}

function Assert-Null {
    <#
    .SYNOPSIS
    Fails unless the value is $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('Value')]$Actual,
        [Parameter(Position = 1)][string]$Because = ''
    )
    if ($null -ne $Actual) { throw "Expected null, got [$Actual]. $Because" }
}

function Assert-NotNull {
    <#
    .SYNOPSIS
    Fails when the value is $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('Value')]$Actual,
        [Parameter(Position = 1)][string]$Because = ''
    )
    if ($null -eq $Actual) { throw "Expected a value, got null. $Because" }
}

function Assert-Match {
    <#
    .SYNOPSIS
    Fails unless the value matches the regular expression.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Pattern,
        [Parameter(Position = 1)][string]$Actual,
        [Parameter(Position = 2)][string]$Because = ''
    )
    if ($Actual -notmatch $Pattern) { throw "Expected [$Actual] to match '$Pattern'. $Because" }
}

function Assert-Throw {
    <#
    .SYNOPSIS
    Fails unless the scriptblock throws, optionally requiring the message to
    match a pattern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('Action')][scriptblock]$Script,
        [Parameter(Position = 1)][string]$Match = '',
        [Parameter(Position = 2)][string]$Because = ''
    )
    $threw = $false
    try {
        & $Script
    } catch {
        $threw = $true
        if ($Match -and ($_.Exception.Message -notmatch $Match)) {
            throw "Threw, but message '$($_.Exception.Message)' did not match '$Match'. $Because"
        }
    }
    if (-not $threw) { throw "Expected a throw. $Because" }
}

function Assert-NoFinding {
    <#
    .SYNOPSIS
    Fails when a collected finding list is non-empty, reporting every entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][Alias('Findings')][string[]]$Finding,
        [Parameter(Position = 1)][string]$Because = ''
    )
    $list = @($Finding | Where-Object { $_ })
    if ($list.Count -gt 0) { throw ("$Because`n  " + ($list -join "`n  ")) }
}

# --- REGION: Scaffolds
function Get-YurunaTestRepoRoot {
    <#
    .SYNOPSIS
    The repository root, from the calling suite's own location.
    .DESCRIPTION
    The suites derived this 12 different ways across 63 assignments, two
    spellings accounting for most of them and returning the same path. -Depth
    exists because the suites do not all sit at the same level: those under
    test/modules/ are two below the root, and host/modules/ is two as well, but
    a suite added elsewhere would not be -- so the walk is stated, not assumed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SuiteDirectory,
        [int]$Depth = 2
    )
    $path = $SuiteDirectory
    for ($i = 0; $i -lt $Depth; $i++) { $path = Split-Path -Parent $path }
    (Resolve-Path -LiteralPath $path).Path
}

function New-YurunaTestTempDir {
    <#
    .SYNOPSIS
    A fresh, empty, uniquely-named temp directory for one test case.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a throwaway directory under the temp path; there is nothing for an operator to confirm.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Prefix = 'yuruna-test')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("$Prefix-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $dir
    $dir
}

function Remove-YurunaTestTempDir {
    <#
    .SYNOPSIS
    Removes a directory created by New-YurunaTestTempDir, never throwing.
    .DESCRIPTION
    Cleanup runs in a finally block, where a throw would replace the real test
    failure with a tidying-up error and hide what actually went wrong.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removes only a directory this module created under the temp path.')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][string]$Path,
        # A browser profile can stay locked for a moment after its last
        # process is stopped, on Windows especially; a single silent attempt
        # then leaves the whole profile behind for good.
        [ValidateRange(1, 50)][int]$Attempts = 1
    )
    if (-not $Path) { return }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds 300 }
    }
}

function Invoke-YurunaTestGit {
    <#
    .SYNOPSIS
    Runs one git command in a fixture repository and returns its output lines,
    throwing with git's own output when it fails.
    .DESCRIPTION
    Nine suites wrapped git in a runner of their own, and they disagreed on
    whether a failure threw, whether stderr counted and what came back (the
    last line, all lines joined, an array, or nothing). A discarded failure
    lets a fixture that was never built reach an assertion as a half-made
    repository. The lines are returned as strings, stderr included, in the
    order git wrote them; a suite that wants one value takes it from them.
    #>
    [CmdletBinding()]
    [OutputType([string], [object[]])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Argument)
    $output = @(& git -C $Path @Argument 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "git $($Argument -join ' ') failed in ${Path}: $($output -join "`n")" }
    $output
}

function Set-YurunaTestGitIdentity {
    <#
    .SYNOPSIS
    Repository-local settings that keep a fixture repository independent of
    the operator's git configuration.
    .DESCRIPTION
    A fixed identity, commit and tag signing off, no line-ending conversion,
    and hooks pointed at an empty directory inside .git, so a global
    commit.gpgsign, core.autocrlf or core.hooksPath on the machine running the
    suite neither prompts, rewrites fixture bytes nor runs hooks. Every setting
    lives in the repository's own config, so later commits in the fixture need
    no -c flags. Use it directly on a clone; New-YurunaTestGitRepository calls
    it for a repository it creates.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes the config of a throwaway test repository; there is nothing for an operator to confirm.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $gitDir = [string](Invoke-YurunaTestGit -Path $Path -Argument @('rev-parse', '--absolute-git-dir'))
    $noHooks = Join-Path $gitDir.Trim() 'yuruna-no-hooks'
    $null = New-Item -ItemType Directory -Force -Path $noHooks
    foreach ($setting in @(
            @('user.name', 'fixture'), @('user.email', 'fixture@example.invalid'),
            @('commit.gpgsign', 'false'), @('tag.gpgsign', 'false'),
            @('core.autocrlf', 'false'), @('core.hooksPath', $noHooks))) {
        $null = Invoke-YurunaTestGit -Path $Path -Argument (@('config') + $setting)
    }
}

function New-YurunaTestGitRepository {
    <#
    .SYNOPSIS
    A throwaway git repository for one test, on a named branch, with the
    settings of Set-YurunaTestGitIdentity, optionally seeded with one commit.
    .DESCRIPTION
    The suites built these by hand in 22 places and disagreed on what a
    fixture repository needs: some turned commit signing off and the rest
    inherited the machine's commit.gpgsign, so their fixture commits prompt or
    fail where signing is on; some named the initial branch and the rest took
    whatever init.defaultBranch says; two pinned core.autocrlf; and most sent
    git's failures to Out-Null, so a fixture that was never built surfaced as
    an unrelated assertion. -File writes each relative path (UTF-8, no BOM)
    and commits them as the first commit; -AddExisting commits whatever the
    directory already holds instead; -CommitMessage alone makes an empty first
    commit; with none of them the repository stays unborn. -Remote adds an
    origin remote with that URL. The repository's path is returned.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a throwaway repository under a test directory; there is nothing for an operator to confirm.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path,
        [string]$Prefix = 'yuruna-git',
        [string]$Branch = 'main',
        [System.Collections.IDictionary]$File,
        [string]$CommitMessage,
        [string]$Remote,
        [switch]$AddExisting
    )
    if (-not $Path) { $Path = New-YurunaTestTempDir -Prefix $Prefix }
    $null = New-Item -ItemType Directory -Force -Path $Path
    $null = Invoke-YurunaTestGit -Path $Path -Argument @('init', '--quiet', "--initial-branch=$Branch")
    Set-YurunaTestGitIdentity -Path $Path
    if ($Remote) { $null = Invoke-YurunaTestGit -Path $Path -Argument @('remote', 'add', 'origin', $Remote) }
    $hasFile = $File -and $File.Count
    if ($hasFile) {
        foreach ($relative in $File.Keys) {
            $full = Join-Path $Path $relative
            $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            [IO.File]::WriteAllText($full, [string]$File[$relative], [Text.UTF8Encoding]::new($false))
        }
    }
    if ($hasFile -or $AddExisting) {
        $null = Invoke-YurunaTestGit -Path $Path -Argument @('add', '-A')
        $message = if ($CommitMessage) { $CommitMessage } else { 'seed' }
        $null = Invoke-YurunaTestGit -Path $Path -Argument @('commit', '--quiet', '--allow-empty', '-m', $message)
    } elseif ($CommitMessage) {
        $null = Invoke-YurunaTestGit -Path $Path -Argument @('commit', '--quiet', '--allow-empty', '-m', $CommitMessage)
    }
    $Path
}

function Save-YurunaTestGlobal {
    <#
    .SYNOPSIS
    Snapshots the $global:__Yuruna* channels a test is about to change, telling
    an absent variable from one that holds $null.
    .DESCRIPTION
    The entry points publish the host id, run id, cycle folder, log file and
    cycle start to the modules through $global:__Yuruna* variables. Seventeen
    suites set them by hand in four forms -- direct assignment, Set-Variable,
    Remove-Variable and fixture pairs of their own -- and most never put the
    previous value back, so a later block in the same process ran with an
    earlier test's cycle folder or host id. Pair this with
    Restore-YurunaTestGlobal in the matching teardown.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Name)
    $saved = @{}
    foreach ($entry in $Name) {
        if ($entry -cnotmatch '^__Yuruna\w+$') { throw "Save-YurunaTestGlobal: '$entry' is not a `$global:__Yuruna* channel." }
        $variable = Get-Variable -Name $entry -Scope Global -ErrorAction SilentlyContinue
        $saved[$entry] = [pscustomobject]@{ Present = [bool]$variable; Value = $(if ($variable) { $variable.Value } else { $null }) }
    }
    return $saved
}

function Set-YurunaTestGlobal {
    <#
    .SYNOPSIS
    Sets $global:__Yuruna* channels for a test, or removes them with -Remove;
    Save-YurunaTestGlobal first, Restore-YurunaTestGlobal after.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets in-process test globals that the matching teardown restores.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Value = @{}, [string[]]$Remove = @())
    foreach ($entry in @(@($Value.Keys) + $Remove)) {
        if ([string]$entry -cnotmatch '^__Yuruna\w+$') { throw "Set-YurunaTestGlobal: '$entry' is not a `$global:__Yuruna* channel." }
    }
    foreach ($entry in $Value.Keys) { Set-Variable -Name $entry -Scope Global -Value $Value[$entry] -Force }
    foreach ($entry in $Remove) { Remove-Variable -Name $entry -Scope Global -Force -ErrorAction SilentlyContinue }
}

function Restore-YurunaTestGlobal {
    <#
    .SYNOPSIS
    Puts back what Save-YurunaTestGlobal recorded: the previous value, or no
    variable at all where there was none.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test teardown restores the caller globals.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Saved)
    foreach ($entry in $Saved.Keys) {
        if ($Saved[$entry].Present) { Set-Variable -Name $entry -Scope Global -Value $Saved[$entry].Value -Force }
        else { Remove-Variable -Name $entry -Scope Global -Force -ErrorAction SilentlyContinue }
    }
}

function Get-YurunaTestSourceText {
    <#
    .SYNOPSIS
    Returns a source file's text; a host driver's root module reads as the whole
    driver, with its part files inlined where the root loads them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $full = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    if (($full -replace '\\', '/') -notmatch '/host/(macos\.utm|ubuntu\.kvm|windows\.hyper-v)/modules/Yuruna\.Host\.psm1$') {
        return [IO.File]::ReadAllText($full)
    }
    if (-not (Get-Command Get-YurunaSourceText -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Test.DriverSource.psm1') -Global -DisableNameChecking
    }
    return (Get-YurunaSourceText -Path $full)
}

function Get-YurunaTestFileAst {
    <#
    .SYNOPSIS
    Parses a PowerShell file and returns its AST, throwing on a parse error.
    .DESCRIPTION
    39 suites hand-rolled this, and the ones that omitted the error check
    reported a confusing downstream failure instead of naming the file that
    would not parse.

    A host driver's root module (host/<driver>/modules/Yuruna.Host.psm1) is
    read as the whole driver: its part files are inlined where the root loads
    them (Test.DriverSource), so a function found here stays found when it
    moves to a part. Line numbers then count in that inlined text.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $identity = $item.FullName
    $driver = ($identity -replace '\\', '/') -match '/host/(macos\.utm|ubuntu\.kvm|windows\.hyper-v)/modules/Yuruna\.Host\.psm1$'
    $stampItems = if ($driver) { @(Get-ChildItem -LiteralPath $item.DirectoryName -Filter 'Yuruna.Host*' -File) } else { @($item) }
    $stamp = ($stampItems | ForEach-Object { "$($_.Name):$($_.LastWriteTimeUtc.Ticks):$($_.Length)" }) -join '|'
    if (-not (Get-Variable -Name TestAstCache -Scope Script -ErrorAction SilentlyContinue)) { $script:TestAstCache = @{} }
    if ($script:TestAstCache.ContainsKey($identity) -and $script:TestAstCache[$identity].Stamp -eq $stamp) { return $script:TestAstCache[$identity].Ast }
    if ($driver) {
        if (-not (Get-Command Get-YurunaSourceAst -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.DriverSource.psm1') -Global -DisableNameChecking
        }
        $ast = Get-YurunaSourceAst -Path $identity
    } else {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        if ($errors) { throw "$Path does not parse: $($errors[0].Message)" }
    }
    $script:TestAstCache[$identity] = @{ Stamp = $stamp; Ast = $ast }
    $ast
}

function Get-YurunaTestFunctionAst {
    <#
    .SYNOPSIS
    Returns the named function's AST from a file, or $null when it is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Ast')][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory, Position = 1)][Alias('FunctionName')][string]$Name
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') { $Ast = Get-YurunaTestFileAst -Path $Path }
    $wanted = $Name
    $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
        }.GetNewClosure(), $true) | Select-Object -First 1
}

function Get-YurunaTestCommandCallCount {
    <#
    .SYNOPSIS
    Counts the invocations of one command under an AST node.
    .DESCRIPTION
    Counts command nodes only, at any depth, whose statically known name equals
    the wanted one without regard to case. A function definition, an
    Export-ModuleMember bareword, a comment and a string are not invocations,
    which is why a structural guard counts this way instead of matching text.

    The name is compared as written. A module-qualified call carries its
    qualifier, so it is counted under the qualified name alone, and a call
    through a variable or an expression has no static name and is never
    counted. The suites assert exact counts against this rule; folding a
    qualifier away would change every one of them on a file that uses both
    spellings.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory, Position = 1)][Alias('Name')][string]$CommandName
    )
    $wanted = $CommandName
    @($Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted
            }.GetNewClosure(), $true)).Count
}

function Get-YurunaTestCommandArgumentAst {
    <# .SYNOPSIS
    Returns a named command argument, including the -Name:value form.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command, [Parameter(Mandatory)][string]$Name)
    $elements = $Command.CommandElements
    for ($index = 0; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq $Name) {
            if ($element.Argument) { return $element.Argument }
            if ($index + 1 -lt $elements.Count -and $elements[$index + 1] -isnot [Management.Automation.Language.CommandParameterAst]) { return $elements[$index + 1] }
            return $null
        }
    }
    return $null
}

function Get-YurunaTestShellFunction {
    <# .SYNOPSIS
    Lifts one top-level shell function and rejects absent definitions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string[]]$Name)
    $parts = foreach ($functionName in $Name) {
    $pattern = '(?ms)^' + [regex]::Escape($functionName) + '\s*\(\)\s*\{.*?^\}'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { throw "Shell function $Name not found" }
    $match.Value
    }
    return ($parts -join "`n")
}

function Invoke-YurunaTestShell {
    <# .SYNOPSIS
    Runs a temporary LF shell fixture with isolated environment and bounded execution.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Body, [hashtable]$Environment = @{}, [string]$Interpreter = 'bash', [int]$TimeoutSeconds = 30)
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
    $directory = New-YurunaTestTempDir -Prefix 'shell-fixture'
    try {
        $path = Join-Path $directory 'fixture.sh'
        [IO.File]::WriteAllText($path, $Body.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        $result = Invoke-BoundedNativeCommand -FilePath $Interpreter -ArgumentList @($path) -Environment $Environment -TimeoutSeconds $TimeoutSeconds
        if (-not (Test-BoundedNativeResultComplete $result)) {
            throw "Shell fixture '$Interpreter' did not complete: StartError='$($result.StartError)'; Started=$($result.Started); TimedOut=$($result.TimedOut); DrainTimedOut=$($result.DrainTimedOut); OutputTruncated=$($result.OutputTruncated); KillFailed=$($result.KillFailed); DeadlineExhausted=$($result.DeadlineExhausted)"
        }
                # Git Bash prints this warning when a /tmp mount outlives the suite folder it was bound to;
        # it is bash's own diagnostic, never fixture output, so it is kept out of the compared text.
        $stderr = @($result.StdErr -split "`r?`n" | Where-Object { $_ -notmatch '^bash(\.exe)?: warning: could not find /tmp, please create!$' }) -join "`n"
        return @{ Output = ($result.StdOut + $stderr).TrimEnd(); ExitCode = $result.ExitCode }
    } finally { Remove-YurunaTestTempDir $directory }
}

function Save-YurunaTestEnvironment {
    <# .SYNOPSIS
    Snapshots named process environment entries, or every entry with -All,
    while preserving unset versus empty values.
    .DESCRIPTION
    -All is for a test whose subject sets entries the test cannot name in
    advance; Restore-YurunaTestEnvironment -RemoveOthers then also removes what
    was added. Entry names are case-sensitive on Linux and macOS, so that
    snapshot keys them by ordinal name there.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'The -All snapshot is keyed case-sensitively where entry names are, which a literal cannot be.')]
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Name')][AllowEmptyCollection()][string[]]$Name,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All
    )
    if ($All) {
        $saved = if ($IsWindows) { [hashtable]::new([StringComparer]::OrdinalIgnoreCase) } else { [hashtable]::new([StringComparer]::Ordinal) }
        foreach ($item in Get-ChildItem -Path Env:) { $saved[$item.Name] = $item.Value }
        return $saved
    }
    $saved = @{}
    foreach ($entry in $Name) { $saved[$entry] = [Environment]::GetEnvironmentVariable($entry) }
    return $saved
}

function Restore-YurunaTestEnvironment {
    <# .SYNOPSIS
    Restores a fixture environment and removes entries that were originally
    absent; with -RemoveOthers, also every entry the snapshot does not name.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test teardown restores the caller environment.')]
    param([Parameter(Mandatory)][hashtable]$Saved, [switch]$RemoveOthers)
    if ($RemoveOthers) {
        foreach ($item in @(Get-ChildItem -Path Env:)) {
            if (-not $Saved.ContainsKey($item.Name)) { Remove-Item -LiteralPath "Env:$($item.Name)" -ErrorAction SilentlyContinue }
        }
    }
    foreach ($name in $Saved.Keys) {
        if ($null -eq $Saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath "Env:$name" -Value $Saved[$name] }
    }
}

function New-YurunaTestTcpListener {
    <#
    .SYNOPSIS
    A TCP listener on the loopback address for one test, started unless -NoStart.
    .DESCRIPTION
    Port 0 lets the system pick a free port; read it from LocalEndpoint while
    the listener is started, because a stopped listener reports the port it was
    asked for, 0, not the one it held. A test that needs a port nothing listens
    on takes Get-YurunaTestFreePort. -AnyAddress binds every interface, for a
    subject that listens or connects there; -NoStart hands back a listener the
    test starts at a moment of its choosing. The caller stops it in a finally
    block.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Binds a socket for one test case, which the caller stops.')]
    [CmdletBinding()]
    [OutputType([System.Net.Sockets.TcpListener])]
    param([ValidateRange(0, 65535)][int]$Port = 0, [switch]$AnyAddress, [switch]$NoStart)
    $address = if ($AnyAddress) { [System.Net.IPAddress]::Any } else { [System.Net.IPAddress]::Loopback }
    $listener = [System.Net.Sockets.TcpListener]::new($address, $Port)
    if (-not $NoStart) { $listener.Start() }
    return $listener
}

function Get-YurunaTestFreePort {
    <#
    .SYNOPSIS
    A TCP port no listener held at the moment of the call, released for the
    caller to bind or to probe as a port that refuses.
    .DESCRIPTION
    The port is bound on the loopback address (every address with -AnyAddress),
    read while the listener is up and released. Nothing reserves it afterwards,
    so a test binds it at once or uses it as a closed port.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([switch]$AnyAddress)
    $listener = New-YurunaTestTcpListener -AnyAddress:$AnyAddress
    try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

function New-YurunaTestSocketPair {
    <#
    .SYNOPSIS
    Two connected loopback TCP clients, Client and Server, for a test that
    writes on one end and reads on the other.
    .DESCRIPTION
    The listener that joined them is stopped before the pair is returned, so
    only the two connections remain; the caller disposes both in a finally
    block.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a loopback socket pair for one test case, which the caller disposes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $listener = New-YurunaTestTcpListener
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect([System.Net.IPAddress]::Loopback, ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port)
        $server = $listener.AcceptTcpClient()
    } catch {
        $client.Dispose()
        throw
    } finally { $listener.Stop() }
    return [pscustomobject]@{ Client = $client; Server = $server }
}

function New-YurunaTestHttpReply {
    <#
    .SYNOPSIS
    The raw text of one HTTP/1.1 response for Start-YurunaTestHttpResponder.
    .DESCRIPTION
    Content-Length counts the body's UTF-8 bytes and the connection closes after
    the reply. No Content-Type is sent unless one is named: publishers serve
    files without one, and how a client reads such a body is what several tests
    check. A test that needs a malformed or truncated reply writes the text
    itself.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a string; nothing changes.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateRange(100, 599)][int]$StatusCode = 200,
        [AllowEmptyString()][string]$Body = '',
        [string]$ContentType = '',
        [System.Collections.IDictionary]$Header = @{}
    )
    $reason = 'Status'
    if ([Enum]::IsDefined([System.Net.HttpStatusCode], $StatusCode)) {
        $reason = ([string][System.Net.HttpStatusCode]$StatusCode) -creplace '(?<=[a-z])(?=[A-Z])', ' '
    }
    $head = [System.Text.StringBuilder]::new("HTTP/1.1 $StatusCode $reason`r`n")
    if ($ContentType) { [void]$head.Append("Content-Type: $ContentType`r`n") }
    foreach ($name in $Header.Keys) { [void]$head.Append("${name}: $($Header[$name])`r`n") }
    [void]$head.Append("Content-Length: $([System.Text.Encoding]::UTF8.GetByteCount($Body))`r`nConnection: close`r`n`r`n")
    return $head.ToString() + $Body
}

function Start-YurunaTestHttpResponder {
    <#
    .SYNOPSIS
    Serves scripted HTTP replies on a loopback port, one connection each, and
    records every request it reads.
    .DESCRIPTION
    A raw TcpListener rather than HttpListener: HttpListener needs a URL ACL (or
    Administrator) to bind on Windows, which an unattended run cannot assume.
    The listener is started before the serving thread job exists, so a request
    can never arrive before something can accept it.

    -Reply serves its entries in order, one per connection. -Route answers each
    request with the reply of the first pattern its request text matches (a 404
    when none does), for -RequestCount connections. Each request is read whole:
    the head, then as many body bytes as its Content-Length names. -HoldOpen
    keeps each connection open after its reply until the responder is stopped,
    for a test whose subject is a client's deadline: an empty reply then answers
    nothing at all, and a reply shorter than its Content-Length stalls mid-body.
    Stop-YurunaTestHttpResponder ends it and returns the requests.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts a loopback responder for one test case, which the caller stops.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'Every value reaches the job through -ArgumentList into its param() block; the analyzer does not follow that path.')]
    [CmdletBinding(DefaultParameterSetName = 'Reply')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Reply')][AllowEmptyString()][string[]]$Reply,
        [Parameter(Mandatory, ParameterSetName = 'Route')][System.Collections.IDictionary]$Route,
        [Parameter(ParameterSetName = 'Route')][ValidateRange(1, 1000)][int]$RequestCount = 1,
        [switch]$HoldOpen
    )
    $routes = [System.Collections.Generic.List[object]]::new()
    if ($PSCmdlet.ParameterSetName -eq 'Route') {
        foreach ($key in $Route.Keys) { $routes.Add(@([string]$key, [string]$Route[$key])) }
        $count = $RequestCount
    } else { $count = $Reply.Count }
    $notFound = New-YurunaTestHttpReply -StatusCode 404 -Body 'no route matched this request'
    $release = [System.Threading.ManualResetEventSlim]::new($false)
    $listener = New-YurunaTestTcpListener
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $job = Start-ThreadJob -ArgumentList $listener, $Reply, $routes, $count, $notFound, $HoldOpen.IsPresent, $release -ScriptBlock {
        param($Listener, $Replies, $Routes, $Count, $NotFound, $Hold, $Release)
        try {
            for ($n = 0; $n -lt $Count; $n++) {
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 5000
                    $buffer = [System.IO.MemoryStream]::new()
                    $chunk = [byte[]]::new(8192)
                    $headEnd = -1
                    $length = 0
                    try {
                        while ($headEnd -lt 0) {
                            $read = $stream.Read($chunk, 0, $chunk.Length)
                            if ($read -le 0) { break }
                            $buffer.Write($chunk, 0, $read)
                            $headEnd = [System.Text.Encoding]::ASCII.GetString($buffer.ToArray()).IndexOf("`r`n`r`n")
                        }
                        if ($headEnd -ge 0) {
                            $lengthMatch = [regex]::Match([System.Text.Encoding]::ASCII.GetString($buffer.ToArray(), 0, $headEnd), '(?im)^content-length:\s*(\d+)')
                            if ($lengthMatch.Success) { $length = [int]$lengthMatch.Groups[1].Value }
                            while ($buffer.Length - ($headEnd + 4) -lt $length) {
                                $read = $stream.Read($chunk, 0, $chunk.Length)
                                if ($read -le 0) { break }
                                $buffer.Write($chunk, 0, $read)
                            }
                        }
                    } catch [System.IO.IOException] {
                        # A client that stops sending is answered with what it sent.
                        $null = $_
                    }
                    $request = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
                    $request
                    $reply = $NotFound
                    if ($Routes.Count -gt 0) {
                        foreach ($route in $Routes) { if ($request -match $route[0]) { $reply = $route[1]; break } }
                    } else { $reply = [string]$Replies[$n] }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($reply)
                    if ($bytes.Length -gt 0) {
                        $stream.Write($bytes, 0, $bytes.Length)
                        $stream.Flush()
                    }
                    if ($Hold) { [void]$Release.Wait(60000) }
                } finally { $client.Dispose() }
            }
        } finally { $Listener.Stop() }
    }
    return [pscustomobject]@{ Listener = $listener; Port = $port; BaseUrl = "http://127.0.0.1:$port"; Job = $job; Release = $release }
}

function Stop-YurunaTestHttpResponder {
    <#
    .SYNOPSIS
    Ends a responder from Start-YurunaTestHttpResponder and returns the text of
    every request it read, never throwing.
    .DESCRIPTION
    Releases held connections, stops the listener (an accept still waiting for a
    connection ends with it), lets a reply in flight finish and removes the job.
    Cleanup runs in finally blocks, where a throw would replace the test's own
    failure with a tidying-up error.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops a loopback responder this module started for one test case.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowNull()]$Responder, [ValidateRange(1, 60)][int]$TimeoutSeconds = 5)
    if ($null -eq $Responder) { return }
    try { $Responder.Release.Set() } catch { Write-Verbose "Stop-YurunaTestHttpResponder: release failed ($($_.Exception.Message))." }
    try { $Responder.Listener.Stop() } catch { Write-Verbose "Stop-YurunaTestHttpResponder: listener stop failed ($($_.Exception.Message))." }
    $requests = @()
    if ($Responder.Job) {
        $null = $Responder.Job | Wait-Job -Timeout $TimeoutSeconds
        $requests = @($Responder.Job | Receive-Job -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
        $Responder.Job | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    try { $Responder.Release.Dispose() } catch { Write-Verbose "Stop-YurunaTestHttpResponder: release dispose failed ($($_.Exception.Message))." }
    return [string[]]$requests
}

function Enter-TranslationTestEnvironment {
    <# .SYNOPSIS
    Snapshots all translation engines and disables external engines for local fixture work.
    A developer's CLI login or translation command must not draft for real when
    a fixture runs without a key.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]]$Name = @())
    $engines = @('YURUNA_TRANSLATE', 'ANTHROPIC_API_KEY', 'YURUNA_TRANSLATE_KEY_FILE', 'YURUNA_TRANSLATE_ENDPOINT',
        'YURUNA_TRANSLATE_MODEL', 'YURUNA_TRANSLATE_CLI', 'YURUNA_TRANSLATE_CLI_MODEL', 'YURUNA_TRANSLATE_CLI_UNMETERED',
        'YURUNA_TRANSLATE_COMMAND', 'YURUNA_TRANSLATE_COMMAND_LABEL', 'YURUNA_TRANSLATE_AGENT')
    $saved = Save-YurunaTestEnvironment -Name (@($Name) + $engines | Select-Object -Unique)
    $env:YURUNA_TRANSLATE_CLI = '0'; $env:YURUNA_TRANSLATE_COMMAND = '0'
    foreach ($entry in 'YURUNA_TRANSLATE_CLI_MODEL', 'YURUNA_TRANSLATE_CLI_UNMETERED', 'YURUNA_TRANSLATE_COMMAND_LABEL', 'YURUNA_TRANSLATE_AGENT') { Remove-Item -LiteralPath "Env:$entry" -ErrorAction SilentlyContinue }
    return $saved
}

function Get-YurunaTestBrowser {
    <#
    .SYNOPSIS
        Finds a local Chrome or Chromium executable for browser fixtures.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($name in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    # Windows installs Chrome under the program directories and does not put it on PATH.
    if ($IsWindows) {
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if (-not $base) { continue }
            $candidate = Join-Path $base 'Google/Chrome/Application/chrome.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

function Wait-YurunaTestBrowserEndpoint {
    <# .SYNOPSIS
    Waits for the browser's port file within the caller's existing deadline.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$PortFile, [Parameter(Mandatory)][datetime]$Deadline)
    $endpoint = $null
    while (-not $endpoint -and [DateTime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath $PortFile) {
            try { $lines = [IO.File]::ReadAllLines($PortFile) }
            catch {
                $failure = $_.Exception.GetBaseException()
                # Chrome can still own the newly created file during startup.
                # Only the Windows sharing violation is transient here.
                if (-not $IsWindows -or $failure -isnot [IO.IOException] -or ($failure.HResult -band 0xFFFF) -ne 32) { throw }
                $lines = @()
            }
            if ($lines.Count -ge 2 -and $lines[1]) { $endpoint = "ws://127.0.0.1:$($lines[0])$($lines[1])" }
        }
        if (-not $endpoint) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $endpoint) { throw 'the browser did not open a DevTools endpoint' }
    return $endpoint
}

function Stop-YurunaTestBrowserProfile {
    <#
    .SYNOPSIS
        Stops every browser process still running on a test profile directory.
    .DESCRIPTION
        Chrome started from an elevated process on Windows starts itself again
        without elevation, and the process that was started exits. The browser
        that answers the test is then one the test never held, so the profile
        directory on its command line is all that identifies it. Returns how
        many processes it stopped.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops only browsers running on a profile directory this module created for one test.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingCmdletAliases', '',
        Justification = 'The POSIX branch calls native ps; the Windows branch uses CIM and never invokes the Windows ps alias.')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Browser, [Parameter(Mandatory)][string]$ProfileDir)
    if (-not $IsWindows) {
        # Linux and macOS: the same identity, read from the process table. A
        # browser that relaunched itself, or a helper the tree kill missed,
        # keeps writing into the profile the caller is about to remove.
        $ownedArg = '(?:^|\s)--user-data-dir=' + [regex]::Escape($ProfileDir) + '(?:\s|$)'
        $stopped = 0
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $running = @(& ps -eo 'pid=,args=' 2>$null | ForEach-Object {
                    if ("$_" -match '^\s*(\d+)\s+(.*)$' -and [int]$Matches[1] -ne $PID -and $Matches[2] -match $ownedArg) { [int]$Matches[1] }
                })
            foreach ($processId in $running) {
                try { Stop-Process -Id $processId -Force -ErrorAction Stop; $stopped++ } catch { $null = $_ }
            }
            if ($running.Count) { Start-Sleep -Milliseconds 200 }
        } while ($running.Count -and [DateTime]::UtcNow -lt $deadline)
        return $stopped
    }
    $image = [IO.Path]::GetFileName($Browser).Replace("'", "''")
    $owned = '--user-data-dir="?' + [regex]::Escape($ProfileDir) + '(?:"|\s|$)'
    $stopped = 0
    # Asked again until nothing answers: a child process outlives its browser
    # for a moment, and the caller removes the profile directory next, which
    # stays locked until the last of them is gone.
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $running = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = '$image'" -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.CommandLine -match $owned })
        foreach ($candidate in $running) {
            # One that exits between the listing and the stop is already what was wanted.
            try { Stop-Process -Id $candidate.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { $null = $_ }
        }
        if ($running.Count) { Start-Sleep -Milliseconds 200 }
    } while ($running.Count -and [DateTime]::UtcNow -lt $deadline)
    return $stopped
}

function Get-YurunaTestBrowserDomCdp {
    <#
    .SYNOPSIS
        The rendered DOM of a page, read over the DevTools protocol, for hosts whose
        browser prints nothing for --dump-dom.
    .DESCRIPTION
        Mirrors --virtual-time-budget: navigate, wait for the document to load,
        then grant virtual time and read the document when the budget expires.
        The browser is stopped afterwards, including one that replaced the
        process this started.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Browser,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ProfileDir,
        [int]$BudgetMs = 5000,
        [int]$TimeoutSeconds = 45
    )
    $start = [Diagnostics.ProcessStartInfo]::new($Browser)
    foreach ($argument in @('--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--no-default-browser-check',
            "--user-data-dir=$ProfileDir", '--remote-debugging-port=0', 'about:blank')) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    $socket = $null
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $portFile = Join-Path $ProfileDir 'DevToolsActivePort'
        $endpoint = Wait-YurunaTestBrowserEndpoint -PortFile $portFile -Deadline $deadline
        $socket = [Net.WebSockets.ClientWebSocket]::new()
        if (-not $socket.ConnectAsync([Uri]$endpoint, [Threading.CancellationToken]::None).Wait(15000)) { throw 'could not connect to the DevTools endpoint' }

        $state = @{ Id = 0 }
        $receive = {
            $builder = [Text.StringBuilder]::new()
            $segment = [ArraySegment[byte]]::new([byte[]]::new(65536))
            do {
                $left = [int][Math]::Max(1000, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                $task = $socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)
                if (-not $task.Wait($left)) { throw 'the DevTools endpoint stopped answering' }
                $null = $builder.Append([Text.Encoding]::UTF8.GetString($segment.Array, 0, $task.Result.Count))
            } while (-not $task.Result.EndOfMessage)
            return ($builder.ToString() | ConvertFrom-Json)
        }.GetNewClosure()
        $send = {
            param([string]$Method, [hashtable]$Params = @{}, [string]$SessionId)
            $state.Id++
            $want = $state.Id
            $message = @{ id = $want; method = $Method; params = $Params }
            if ($SessionId) { $message.sessionId = $SessionId }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($message | ConvertTo-Json -Depth 8 -Compress))
            $null = $socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(15000)
            while ($true) {
                $reply = & $receive
                if ($reply.id -eq $want) {
                    if ($reply.error) { throw "DevTools error on ${Method}: $($reply.error.message)" }
                    return $reply.result
                }
            }
        }.GetNewClosure()

        $target = & $send 'Target.createTarget' @{ url = 'about:blank' }
        $session = (& $send 'Target.attachToTarget' @{ targetId = $target.targetId; flatten = $true }).sessionId
        $null = & $send 'Page.navigate' @{ url = $Url } $session
        # Virtual time must not be paused while the navigation is still in flight, so the
        # budget starts once the document has loaded.
        $loaded = $false
        while (-not $loaded -and [DateTime]::UtcNow -lt $deadline) {
            $readyState = (& $send 'Runtime.evaluate' @{ expression = 'document.readyState'; returnByValue = $true } $session).result.value
            if ($readyState -eq 'complete') { $loaded = $true } else { Start-Sleep -Milliseconds 100 }
        }
        $null = & $send 'Emulation.setVirtualTimePolicy' @{ policy = 'pauseIfNetworkFetchesPending'; budget = $BudgetMs } $session
        $spent = $false
        while (-not $spent) {
            $notice = & $receive
            if ($notice.method -eq 'Emulation.virtualTimeBudgetExpired') { $spent = $true }
        }
        $result = & $send 'Runtime.evaluate' @{ expression = 'document.documentElement.outerHTML'; returnByValue = $true } $session
        return [string]$result.result.value
    } finally {
        if ($socket) { $socket.Dispose() }
        # A launcher that has already exited handed the session to a browser it
        # started, so killing the launcher's tree would stop nothing.
        $replaced = $process -and $process.HasExited
        if ($process -and -not $process.HasExited) { try { $process.Kill($true); [void]$process.WaitForExit(5000) } catch { $null = $_ } }
        if ($process) { $process.Dispose() }
        if ($replaced) { $null = Stop-YurunaTestBrowserProfile -Browser $Browser -ProfileDir $ProfileDir }
    }
}
function Get-YurunaTestBrowserDom {
    <#
    .SYNOPSIS
        The rendered DOM of a local page after a five-second virtual-time budget.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Browser, [Parameter(Mandatory)][string]$Path)
    if ($IsWindows) {
        $browserProfile = New-YurunaTestTempDir -Prefix 'yuruna-browser-profile'
        try {
            return (Get-YurunaTestBrowserDomCdp -Browser $Browser -Url ([Uri]::new([IO.Path]::GetFullPath($Path)).AbsoluteUri) -ProfileDir $browserProfile)
        } finally {
            $null = Stop-YurunaTestBrowserProfile -Browser $Browser -ProfileDir $browserProfile
            Remove-YurunaTestTempDir $browserProfile -Attempts 10
        }
    }
    return (& $Browser --headless --disable-gpu --no-sandbox --virtual-time-budget=5000 --dump-dom "file://$Path" 2>$null | Out-String)
}
function Invoke-YurunaTestBrowserResult {
    <#
    .SYNOPSIS
        Renders a fixture with an isolated browser profile and a bounded process tree.
        On Linux, read the target element from the DOM returned by --dump-dom:
        the dump also echoes the page's inline script, which can contain the
        same marker before the rendered element.
    #>
    [CmdletBinding()]
    [OutputType([Text.RegularExpressions.Match])]
    param([Parameter(Mandatory)][string]$Browser, [Parameter(Mandatory)][string]$Path, [string]$ElementId = 'out')
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
    $browserProfile = New-YurunaTestTempDir -Prefix 'yuruna-browser-profile'
    try {
        $url = [Uri]::new([IO.Path]::GetFullPath($Path)).AbsoluteUri
        if ($IsWindows -or $IsMacOS) {
            # chrome.exe writes nothing to a redirected stdout, so --dump-dom is unusable
            # there. On macOS, Chrome never finishes --dump-dom when it is given a fresh
            # --user-data-dir, so the DOM is read over DevTools on both.
            $dom = Get-YurunaTestBrowserDomCdp -Browser $Browser -Url $url -ProfileDir $browserProfile
            return [regex]::Match($dom, '(?s)<pre id="' + [regex]::Escape($ElementId) + '">(.*?)</pre>')
        }
        $result = Invoke-BoundedNativeCommand -FilePath $Browser -ArgumentList @('--headless', '--disable-gpu', '--no-sandbox', "--user-data-dir=$browserProfile", '--virtual-time-budget=5000', '--dump-dom', $url) -TimeoutSeconds 30
        if (-not (Test-BoundedNativeResultComplete $result) -or $result.ExitCode -ne 0) { throw "Browser render failed: $($result.StdErr)" }
        return [regex]::Match($result.StdOut, '(?s)<pre id="' + [regex]::Escape($ElementId) + '">(.*?)</pre>')
    } finally {
        $null = Stop-YurunaTestBrowserProfile -Browser $Browser -ProfileDir $browserProfile
        Remove-YurunaTestTempDir $browserProfile -Attempts 10
    }
}

Export-ModuleMember -Function Get-YurunaTestBrowser, Get-YurunaTestBrowserDom, Invoke-YurunaTestBrowserResult, Save-YurunaTestEnvironment, Restore-YurunaTestEnvironment, Enter-TranslationTestEnvironment, Get-YurunaTestCommandArgumentAst, Get-YurunaTestShellFunction, Invoke-YurunaTestShell, `
    New-YurunaTestTcpListener, Get-YurunaTestFreePort, New-YurunaTestSocketPair, New-YurunaTestHttpReply, Start-YurunaTestHttpResponder, Stop-YurunaTestHttpResponder, `
    Assert-True, Assert-False, Assert-Equal, Assert-StringEqual, Assert-NotEqual, `
    Assert-Null, Assert-NotNull, Assert-Match, Assert-Throw, Assert-NoFinding, `
    Get-YurunaTestRepoRoot, New-YurunaTestTempDir, Remove-YurunaTestTempDir, New-YurunaTestGitRepository, Set-YurunaTestGitIdentity, Invoke-YurunaTestGit, `
    Save-YurunaTestGlobal, Set-YurunaTestGlobal, Restore-YurunaTestGlobal, `
    Get-YurunaTestSourceText, Get-YurunaTestFileAst, Get-YurunaTestFunctionAst, Get-YurunaTestCommandCallCount
