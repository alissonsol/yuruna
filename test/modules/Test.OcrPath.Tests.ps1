<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42c11373-6ab6-4218-89d7-d152de3a1e3a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ocr path pester
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
    Pester coverage for the long-path contract between the harness's captures
    and the native OCR engines that have to read them.
.DESCRIPTION
    A capture written to a path past the Windows long-path ceiling is readable
    by every PowerShell guard around it and unreadable by the engine at the end
    of the chain, so the failure arrives as a screen with no text on it rather
    than as an error. Nothing downstream can tell that apart from a blank
    console, which is why the ceiling is enforced here instead of being left to
    each engine to discover.

    The ceiling is a Windows rule, so the arithmetic is asserted through the
    predicate's explicit -WindowsHost parameter: a guard that only runs on
    Windows is a guard that goes unrun until a lab cycle fails on it. The
    filesystem behavior around the handle runs on every platform.

    Throw-based assertions, Pester 3.4 / 5+.
    Run: Invoke-Pester -Path test/modules/Test.OcrPath.Tests.ps1
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulesDir = $here
Import-Module (Join-Path $here 'Test.Assert.psm1')   -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.OcrPath.psm1')  -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Catalog.psm1') -Force -DisableNameChecking

$script:tesseractPath = Join-Path $modulesDir 'Test.Tesseract.psm1'
$script:ocrEnginePath = Join-Path $modulesDir 'Test.OcrEngine.psm1'

function Get-ModuleAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Module not found: $Path" }
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    return $ast
}

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)]$RootAst, [Parameter(Mandatory)][string]$FunctionName)
    $wanted = $FunctionName
    return ($RootAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
    }, $true) | Select-Object -First 1)
}

# True iff the AST subtree invokes a command named $CommandName.
function Test-AstCallsCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    $wanted = $CommandName
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted
    }, $true)
    return (@($hits).Count -gt 0)
}

# True iff the release call sits in a finally block, not merely somewhere in the
# function: a release on the success path alone leaks the copy whenever the
# engine throws, which is precisely when a long path is involved.
function Test-AstReleasesInFinally {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$FuncAst, [Parameter(Mandatory)][string]$CommandName)
    $wanted = $CommandName
    $tries = $FuncAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)
    foreach ($t in $tries) {
        if (-not $t.Finally) { continue }
        $hits = $t.Finally.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted
        }, $true)
        if (@($hits).Count -gt 0) { return $true }
    }
    return $false
}

$script:tessAst   = Get-ModuleAst -Path $script:tesseractPath
$script:engineAst = Get-ModuleAst -Path $script:ocrEnginePath

# The two lengths a lab cycle actually produced from one capture directory: the
# poll frames were read by both engines and the confirmation probe was read by
# neither. They bracket the ceiling from below and above.
$script:readableLength   = 252
$script:unreadableLength = 280

function New-PathOfLength {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a string; touches nothing outside the caller.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Length)
    $head = 'C:\yuruna\'
    return $head + ('a' * ($Length - $head.Length - 4)) + '.png'
}
}

Describe 'the native path ceiling is enforced where the lab found it' {
    It 'passes a path of the length both engines read' {
        $p = New-PathOfLength -Length $script:readableLength
        Assert-Equal -Expected $script:readableLength -Actual $p.Length -Because 'the fixture must be the length it claims'
        Assert-False (Test-OcrPathBeyondNativeCeiling -Path $p -WindowsHost $true) -Because `
            'frames at this length were read by tesseract and WinRT alike; copying them would be pure overhead'
    }
    It 'rejects a path of the length neither engine could open' {
        $p = New-PathOfLength -Length $script:unreadableLength
        Assert-True (Test-OcrPathBeyondNativeCeiling -Path $p -WindowsHost $true) -Because `
            'tesseract answered "cannot read input file" and WinRT threw on a capture at this length'
    }
    It 'splits the two sides of MAX_PATH exactly' {
        Assert-True (Test-OcrPathBeyondNativeCeiling -Path ('c' * 260) -WindowsHost $true) -Because `
            'MAX_PATH counts the terminating NUL, so 260 is the first length the engines refuse'
        Assert-False (Test-OcrPathBeyondNativeCeiling -Path ('c' * 259) -WindowsHost $true) -Because `
            'the longest accepted path must still take the no-copy path; a margin here copies readable frames every poll'
    }
    It 'never fires off Windows, where the ceiling does not exist' {
        Assert-False (Test-OcrPathBeyondNativeCeiling -Path ('c' * 4000) -WindowsHost $false) -Because `
            'PATH_MAX on the KVM and UTM hosts is far above anything the cycle folder can build'
    }
}

Describe 'Resolve-OcrImagePath hands back a real path and Clear-OcrImagePath respects ownership' {
    It 'returns the original path, uncopied, for a path the engine can open' {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ocrpath-short-{0}.png" -f $PID)
        Set-Content -LiteralPath $f -Value 'x' -NoNewline
        try {
            $h = Resolve-OcrImagePath -ImagePath $f
            Assert-False ([bool]$h.IsCopy) 'a short path must not be copied'
            Assert-Equal -Expected (Resolve-Path -LiteralPath $f).Path -Actual ([string]$h.Path) -Because `
                'the engine must be pointed at the capture itself when it can open it'
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    It 'leaves the capture on disk when the handle does not own a copy' {
        # The destructive misread of this contract: treating every handle as a
        # copy would delete the very frames the failure path exists to preserve.
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ocrpath-keep-{0}.png" -f $PID)
        Set-Content -LiteralPath $f -Value 'x' -NoNewline
        try {
            Clear-OcrImagePath -Handle (Resolve-OcrImagePath -ImagePath $f)
            Assert-True (Test-Path -LiteralPath $f) 'a capture the helper did not copy must survive the release'
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    It 'deletes the temporary file when the handle does own a copy' {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ocrpath-owned-{0}.png" -f $PID)
        Set-Content -LiteralPath $f -Value 'x' -NoNewline
        Clear-OcrImagePath -Handle @{ Path = $f; IsCopy = $true }
        Assert-False (Test-Path -LiteralPath $f) 'a copy the helper made must not outlive the OCR call'
    }
    It 'is a no-op on a null handle and on a second release' {
        Clear-OcrImagePath -Handle $null
        $gone = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ocrpath-gone-{0}.png" -f $PID)
        Clear-OcrImagePath -Handle @{ Path = $gone; IsCopy = $true }
        Assert-True $true 'neither call may throw; a cleanup error must never become the OCR error'
    }
}

Describe 'every native OCR entry point routes its image through the helper' {
    It 'Invoke-TesseractOcr resolves the path and releases it in a finally' {
        $fn = Get-FunctionAst -RootAst $script:tessAst -FunctionName 'Invoke-TesseractOcr'
        Assert-True (Test-AstCallsCommand -Ast $fn -CommandName 'Resolve-OcrImagePath') 'the text path must go through the helper'
        Assert-True (Test-AstReleasesInFinally -FuncAst $fn -CommandName 'Clear-OcrImagePath') `
            'a release only on the success path leaks the copy on exactly the runs that failed'
    }
    It 'Get-TesseractWordBox resolves the path and releases it in a finally' {
        $fn = Get-FunctionAst -RootAst $script:tessAst -FunctionName 'Get-TesseractWordBox'
        Assert-True (Test-AstCallsCommand -Ast $fn -CommandName 'Resolve-OcrImagePath') 'word boxes read off an unopenable image come back empty, not failed'
        Assert-True (Test-AstReleasesInFinally -FuncAst $fn -CommandName 'Clear-OcrImagePath') 'the TSV path owns its copy the same way'
    }
    It 'Invoke-WinRtOcr resolves the path and releases it in a finally' {
        $fn = Get-FunctionAst -RootAst $script:engineAst -FunctionName 'Invoke-WinRtOcr'
        Assert-True (Test-AstCallsCommand -Ast $fn -CommandName 'Resolve-OcrImagePath') `
            'StorageFile rejects the same paths tesseract does, in the worker and the one-shot alike'
        Assert-True (Test-AstReleasesInFinally -FuncAst $fn -CommandName 'Clear-OcrImagePath') `
            'the worker path returns early, so only a finally releases the copy on both routes'
    }
    It 'both modules import the shared leaf helper' {
        foreach ($p in @($script:tesseractPath, $script:ocrEnginePath)) {
            $src = Get-Content -LiteralPath $p -Raw
            Assert-True ($src -match 'Import-Module[^\n]*Test\.OcrPath\.psm1') "$(Split-Path -Leaf $p) must import Test.OcrPath"
        }
    }
}

Describe 'the WinRT one-shot cannot report a failed read as an empty screen' {
    It 'throws when the helper wrote a diagnostic and no text came back' {
        # powershell.exe -File exits 0 even when the script it ran threw, so the
        # exit code alone leaves a dead reader looking like a blank console.
        $fn = Get-FunctionAst -RootAst $script:engineAst -FunctionName 'Invoke-WinRtOcr'
        $guards = @($fn.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -ceq '-not $text -and $errText'
        }, $true))
        Assert-Equal 1 $guards.Count 'the failed empty-read branch must remain in the actual OCR provider'
        $harness = [scriptblock]::Create(@'
param($text, $errText, $catalogLocale)
function Format-YurunaOperatorMessage {
    param($Key, $Arguments)
    Format-CatalogMessage -Key $Key -Arguments $Arguments -Locale $catalogLocale
}
try {
    __GUARD__
    @{ Threw = $false; Message = '' }
} catch { @{ Threw = $true; Message = $_.Exception.Message } }
'@.Replace('__GUARD__', $guards[0].Extent.Text))
        $detail = 'helper <diagnostic> "quoted" ' + [char]0x8336 + [char]0x202e
        $failed = & $harness '' $detail 'en-US'
        Assert-True $failed.Threw 'stderr from a text-less successful-exit helper must fail the OCR read'
        Assert-Equal ('WinRT OCR read no text and reported: ' + $detail) $failed.Message `
            'the English diagnostic or external detail changed'
        $localized = & $harness '' $detail 'qps-Ploc'
        Assert-True $localized.Threw 'localized prose must preserve the failed-read classification'
        Assert-True ($localized.Message.Contains($detail)) 'localization altered the external diagnostic'
        Assert-False ($localized.Message -ceq $failed.Message) 'the actual exception bypassed the selected catalog'
        Assert-False (& $harness '' '' 'en-US').Threw 'a blank screen without a diagnostic is a successful empty read'
        Assert-False (& $harness 'recognized text' $detail 'en-US').Threw 'the empty-read guard rejected real OCR text'
    }
}
