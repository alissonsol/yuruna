<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42ac2b74-32fe-4772-8fad-0e7833bd2f68
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test log tee pester
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
    Structural Pester guard on automation/Yuruna.Log.psm1: the append-to-transcript
    tee block lives in one private helper, and every Write-* proxy delegates to it.
.DESCRIPTION
    The six Write-* overrides once carried a verbatim copy of the same
    File::AppendAllText(HtmlEncode(...)) tee block, so a change to the log line
    format or the non-fatal-append handling had to be made in six places. These
    AST guards assert the block is centralized in Add-YurunaLogLine, that each
    proxy delegates to it, that the raw AppendAllText call now appears exactly
    once, and that the helper stays private. The first Describe is AST/source-only
    -- it parses the module without importing it. The second Describe imports the
    module and drives the proxies against a temp transcript file, pinning the
    severity tagging, the HTML encoding, and the unconditional warning mirror as
    observable behavior rather than as source shape.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'automation/Yuruna.Log.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-ModuleAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    return $ast
}

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)]$RootAst, [Parameter(Mandatory)][string]$FunctionName)
    $f = $RootAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
    if (-not $f) { throw "Function '$FunctionName' not found." }
    return $f
}

# True iff the AST subtree invokes a command named $CommandName.
function Test-AstCallsCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    Write-Verbose "Searching for a call to '$CommandName'"
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName
    }, $true)
    return (@($hits).Count -gt 0)
}

# Count of static/instance method invocations whose member name is $Method.
function Get-MethodCallCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Method)
    Write-Verbose "Counting method calls to '$Method'"
    $hits = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $n.Member.Value -eq $Method
    }, $true)
    return @($hits).Count
}

$rootAst = Get-ModuleAst -Path $modulePath
$script:proxies = @('Write-Output', 'Write-Error', 'Write-Warning', 'Write-Debug', 'Write-Verbose', 'Write-Information')

# A temp file stands in for the per-cycle transcript; these seed/restore the
# Yuruna.Log cross-module global handle, so PSAvoidGlobalVars is suppressed on
# the confined helpers rather than the It blocks.
#
# They live in the top-level BeforeAll rather than at file scope: file-scope
# code runs on the discovery pass, which is over before any It body executes,
# so a helper defined there is not reliably resolvable from one. BeforeAll runs
# on the run pass and its definitions reach every Describe below it.
function New-TranscriptFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test must seed the Yuruna.Log transcript-handle global the proxies read.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: temp file + seeds/saves globals; no production state.')]
    [OutputType([hashtable])]
    param()
    $saved = @{ LogFile = $global:__YurunaLogFile; Warn = $global:WarningPreference; Info = $global:InformationPreference }
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-tee-' + [guid]::NewGuid().ToString('N') + '.html')
    [System.IO.File]::WriteAllText($file, '')
    $global:__YurunaLogFile = $file
    return @{ File = $file; Saved = $saved }
}

function Restore-TranscriptFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test teardown restores the globals it saved.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test teardown: restores saved globals and removes the temp file.')]
    param([Parameter(Mandatory)][hashtable]$Fixture)
    $global:__YurunaLogFile      = $Fixture.Saved.LogFile
    $global:WarningPreference     = $Fixture.Saved.Warn
    $global:InformationPreference = $Fixture.Saved.Info
    if ($Fixture.File) { Remove-Item -LiteralPath $Fixture.File -Force -ErrorAction SilentlyContinue }
}

}

Describe 'yuruna-log-tee -- the append-to-transcript block is centralized in one helper' {
    It 'defines a single private Add-YurunaLogLine tee helper' {
        Assert-True ([bool](Get-FunctionAst -RootAst $rootAst -FunctionName 'Add-YurunaLogLine')) `
            'the six copied tee blocks must collapse into one shared helper'
    }
    It 'each Write-* proxy delegates its append to Add-YurunaLogLine' {
        foreach ($p in $script:proxies) {
            $f = Get-FunctionAst -RootAst $rootAst -FunctionName $p
            Assert-True (Test-AstCallsCommand -Ast $f -CommandName 'Add-YurunaLogLine') `
                "$p must tee via Add-YurunaLogLine, not an inline AppendAllText"
        }
    }
    It 'each proxy delegates its OWN message source (guards a wrong-variable delegation)' {
        $expected = @{
            'Write-Output'     = '"$item"'
            'Write-Error'      = '$text'
            'Write-Warning'    = '$Message'
            'Write-Debug'      = '$Message'
            'Write-Verbose'    = '$Message'
            'Write-Information' = '"$MessageData"'
        }
        foreach ($p in $script:proxies) {
            $f = Get-FunctionAst -RootAst $rootAst -FunctionName $p
            $call = $f.FindAll({
                param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-YurunaLogLine'
            }, $true) | Select-Object -First 1
            Assert-True ($null -ne $call) "$p must call Add-YurunaLogLine"
            $argText = if (@($call.CommandElements).Count -ge 2) { $call.CommandElements[1].Extent.Text } else { '' }
            Assert-True ($argText -eq $expected[$p]) "$p must delegate its own source ($($expected[$p])), got '$argText'"
        }
    }
    It 'the raw File::AppendAllText call now appears exactly once (inside the helper)' {
        $n = Get-MethodCallCount -Ast $rootAst -Method 'AppendAllText'
        Assert-True ($n -eq 1) "expected exactly one AppendAllText call after dedup, found $n"
    }
    It 'the helper stays private -- Export-ModuleMember exports only the six proxies' {
        $exportCalls = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch 'Add-YurunaLogLine') 'Add-YurunaLogLine must not be exported (it is a private helper)'
        foreach ($p in $script:proxies) {
            Assert-True ($exportText -match [regex]::Escape($p)) "$p must remain exported"
        }
    }
}

Describe 'yuruna-log-tee -- severity tags and unconditional warning mirroring' {
    # The import is a run-phase side effect, so it belongs in BeforeAll: a
    # Describe body is executed during discovery, where BeforeAll-assigned
    # values such as $modulePath do not exist yet. Importing there would bind
    # -Name to $null, abort the body, and silently emit zero It blocks -- the
    # Describe would then pass while asserting nothing.
    # -Global is required: the It bodies run in Pester's scope, so the Write-*
    # overrides must replace the built-ins session-wide to be reached at all.
    BeforeAll {
        Import-Module $modulePath -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue
    }

    AfterAll {
        # The session-wide overrides outlive this file otherwise; unloading
        # restores the real Write-* cmdlets for whatever runs next.
        Remove-Module -Name 'Yuruna.Log' -Force -ErrorAction SilentlyContinue
    }

    It 'tags each transcript record with a log-<severity> CSS class' {
        $fx = New-TranscriptFixture
        try {
            $global:InformationPreference = 'Continue'
            Write-Error 'boom' -ErrorAction SilentlyContinue
            Write-Information 'note'
            $content = Get-Content -Raw -LiteralPath $fx.File
            Assert-True ($content -match 'class="log-error"')       'error record carries the log-error class'
            Assert-True ($content -match 'class="log-information"')  'information record carries the log-information class'
        } finally { Restore-TranscriptFixture -Fixture $fx }
    }

    It 'mirrors a Warning to the transcript even when the console is quiet (WarningPreference=SilentlyContinue)' {
        $fx = New-TranscriptFixture
        try {
            $global:WarningPreference = 'SilentlyContinue'
            Write-Warning 'quiet-warning'
            $content = Get-Content -Raw -LiteralPath $fx.File
            Assert-True ($content -match 'class="log-warning"') 'the warning record is tagged log-warning'
            Assert-True ($content -match 'quiet-warning')       'the warning body reaches the transcript despite the quiet console'
        } finally { Restore-TranscriptFixture -Fixture $fx }
    }

    It 'gives the transcript an outline by promoting step rules to headings' {
        $fx = New-TranscriptFixture
        try {
            $global:InformationPreference = 'Continue'
            Write-Information '----- [2/11] workload.guest.example -----'
            Write-Information 'ordinary output that happens to mention [2/11]'
            $content = Get-Content -Raw -LiteralPath $fx.File
            Assert-True ($content -match 'class="log-information log-step" role="heading" aria-level="2"') 'the step rule is exposed as a level-2 heading'
            Assert-True (([regex]::Matches($content, 'role="heading"')).Count -eq 1) 'a line that merely mentions a step number is not promoted'
        } finally { Restore-TranscriptFixture -Fixture $fx }
    }

    It 'HTML-encodes the message body while emitting the span markup verbatim' {
        $fx = New-TranscriptFixture
        try {
            $global:WarningPreference = 'SilentlyContinue'
            Write-Warning 'a<b>c'
            $content = Get-Content -Raw -LiteralPath $fx.File
            Assert-True ($content -match 'a&lt;b&gt;c')          'angle brackets in the message are HTML-encoded'
            Assert-True ($content -match '<span class="log-warning">') 'the span wrapper is emitted as live markup, not escaped'
        } finally { Restore-TranscriptFixture -Fixture $fx }
    }
}

Describe 'yuruna-log-tee -- the transcript preamble' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Log.psm1') -Force -DisableNameChecking
    }

    It 'renders every severity class it writes, with a word cue and not color alone' {
        # The classes were written and thrown away: no stylesheet defined them,
        # so a warning and an ordinary line rendered identically. Assert on the
        # header rather than on a live transcript, because the header is what
        # every transcript -- owner cycle and nested sub-run -- starts from.
        $header = Get-YurunaLogPreamble
        Assert-True ($header -match '<html lang="en"')  'the transcript declares a document language'
        foreach ($sev in @('error', 'warning', 'debug', 'verbose')) {
            Assert-True ($header -match "\.log-$sev\b")      "the header defines a rule for log-$sev"
            Assert-True ($header -match "\.log-$sev::before") "log-$sev carries a text cue, not color alone"
        }
    }
}
