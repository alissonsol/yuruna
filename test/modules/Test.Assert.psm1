<#PSScriptInfo
.VERSION 2026.09.30
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
    param([Parameter(Position = 0)][AllowNull()][string]$Path)
    if (-not $Path) { return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-YurunaTestFileAst {
    <#
    .SYNOPSIS
    Parses a PowerShell file and returns its AST, throwing on a parse error.
    .DESCRIPTION
    39 suites hand-rolled this, and the ones that omitted the error check
    reported a confusing downstream failure instead of naming the file that
    would not parse.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $identity = $item.FullName
    $stamp = "$($item.LastWriteTimeUtc.Ticks):$($item.Length)"
    if (-not (Get-Variable -Name TestAstCache -Scope Script -ErrorAction SilentlyContinue)) { $script:TestAstCache = @{} }
    if ($script:TestAstCache.ContainsKey($identity) -and $script:TestAstCache[$identity].Stamp -eq $stamp) { return $script:TestAstCache[$identity].Ast }
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "$Path does not parse: $($errors[0].Message)" }
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
        if (-not (Test-BoundedNativeResultComplete $result)) { throw "Shell fixture did not complete: $($result.Error)" }
        return @{ Output = ($result.StdOut + $result.StdErr).TrimEnd(); ExitCode = $result.ExitCode }
    } finally { Remove-YurunaTestTempDir $directory }
}

function Save-YurunaTestEnvironment {
    <# .SYNOPSIS
    Snapshots named process environment entries while preserving unset versus empty values.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Name)
    $saved = @{}
    foreach ($entry in $Name) { $saved[$entry] = [Environment]::GetEnvironmentVariable($entry) }
    return $saved
}

function Restore-YurunaTestEnvironment {
    <# .SYNOPSIS
    Restores a fixture environment and removes entries that were originally absent.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test teardown restores the caller environment.')]
    param([Parameter(Mandatory)][hashtable]$Saved)
    foreach ($name in $Saved.Keys) {
        if ($null -eq $Saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath "Env:$name" -Value $Saved[$name] }
    }
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

function Get-YurunaTestBrowserDomCdp {
    <#
    .SYNOPSIS
        The rendered DOM of a page, read over the DevTools protocol, for hosts whose
        browser prints nothing for --dump-dom.
    .DESCRIPTION
        Mirrors --virtual-time-budget: navigate, wait for the document to load,
        then grant virtual time and read the document when the budget expires.
        The browser process is killed afterwards.
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
        $endpoint = $null
        $portFile = Join-Path $ProfileDir 'DevToolsActivePort'
        while (-not $endpoint -and [DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $portFile) {
                $lines = [IO.File]::ReadAllLines($portFile)
                if ($lines.Count -ge 2 -and $lines[1]) { $endpoint = "ws://127.0.0.1:$($lines[0])$($lines[1])" }
            }
            if (-not $endpoint) { Start-Sleep -Milliseconds 200 }
        }
        if (-not $endpoint) { throw 'the browser did not open a DevTools endpoint' }
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
        if ($process -and -not $process.HasExited) { try { $process.Kill($true); [void]$process.WaitForExit(5000) } catch { $null = $_ } }
        if ($process) { $process.Dispose() }
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
        } finally { Remove-YurunaTestTempDir $browserProfile }
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
    } finally { Remove-YurunaTestTempDir $browserProfile }
}

function Get-YurunaTestGeneratedServerText {
    <#
    .SYNOPSIS
        Expands the launcher server template in the calling fixture's scope.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Expand)
    $source = [IO.File]::ReadAllText($Path)
    $template = [regex]::Match($source, '(?ms)^\$serverScript = @"\r?\n(.*?)^"@')
    if (-not $template.Success) { throw "Server template missing in $Path" }
    return & $Expand $template.Groups[1].Value
}

Export-ModuleMember -Function Get-YurunaTestBrowser, Get-YurunaTestBrowserDom, Invoke-YurunaTestBrowserResult, Get-YurunaTestGeneratedServerText, Save-YurunaTestEnvironment, Restore-YurunaTestEnvironment, Enter-TranslationTestEnvironment, Get-YurunaTestCommandArgumentAst, Get-YurunaTestShellFunction, Invoke-YurunaTestShell, `
    Assert-True, Assert-False, Assert-Equal, Assert-StringEqual, Assert-NotEqual, `
    Assert-Null, Assert-NotNull, Assert-Match, Assert-Throw, Assert-NoFinding, `
    Get-YurunaTestRepoRoot, New-YurunaTestTempDir, Remove-YurunaTestTempDir, `
    Get-YurunaTestFileAst, Get-YurunaTestFunctionAst
