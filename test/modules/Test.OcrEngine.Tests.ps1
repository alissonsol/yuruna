<#PSScriptInfo
.VERSION 2026.07.17
.GUID 421e2a7b-3d84-4f61-9a05-8e6d2b9c4f17
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ocr engine pester
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
    Structural Pester guards on Test.OcrEngine.psm1's fallback-path observability
    and error classification.
.DESCRIPTION
    Three cap-ocr-engine hardening invariants, asserted on the parsed AST so a
    comment that merely names a token cannot keep a guard green after the code is
    removed:
      1. The WinRT worker->one-shot fallback increments a module-scoped counter
         and emits a rate-limited 'ocr_worker_fallback' event (not just Verbose-logged).
      2. Get-VisionOcrBinaryPath carries a process-lifetime negative cache
         ($script:VisionOcrBinaryProbeFailed): it short-circuits on that flag,
         latches it via Write-VisionOcrSlowPathEvent (one-time 'ocr_vision_slowpath'
         event), pins the native-command EAP, and Clear-VisionOcrBinaryCache
         resets it.
      3. The WinRT one-shot path pins $PSNativeCommandUseErrorActionPreference
         and includes stdout string lines (not ErrorRecord-only) in the failure
         detail so a non-zero exit is always diagnosable.

    AST/source-only -- no OCR engine, worker process, or host I/O is required.
    The throw-based Assert-* helpers are defined at script scope and referenced
    from It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split
    hides top-level helpers from It blocks).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.OcrEngine.psm1'

function Assert-True { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Tail-match a VariablePath so 'Foo', '$script:Foo', '$global:Foo' all match 'Foo'.
function Test-VarPathIs {
    param([Parameter(Mandatory)]$VariablePath, [Parameter(Mandatory)][string]$Name)
    return ($VariablePath.UserPath -match ("(^|:)" + [regex]::Escape($Name) + "$"))
}

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
    $func = $RootAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
    if (-not $func) { throw "Function '$FunctionName' not found." }
    return $func
}

# True iff the AST subtree assigns to a variable whose path tail-matches $VarName.
function Test-AstAssignsVar {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Searching for an assignment to '$VarName'"
    $hits = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        ($n.Left.VariablePath.UserPath -match ("(^|:)" + [regex]::Escape($VarName) + "$"))
    }, $true)
    return (@($hits).Count -gt 0)
}

# True iff the AST subtree references a variable whose path tail-matches $VarName.
function Test-AstReferencesVar {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Searching for a reference to '$VarName'"
    $hits = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
        ($n.VariablePath.UserPath -match ("(^|:)" + [regex]::Escape($VarName) + "$"))
    }, $true)
    return (@($hits).Count -gt 0)
}

# True iff the AST subtree contains a string constant equal to $Value.
function Test-AstContainsString {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Value)
    Write-Verbose "Searching for string constant '$Value'"
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq $Value
    }, $true)
    return (@($hits).Count -gt 0)
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

# True iff the AST subtree has an if-statement whose condition references $VarName.
function Test-AstIfConditionOnVar {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Searching for an if-condition on '$VarName'"
    $ifs = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)
    foreach ($if in $ifs) {
        foreach ($clause in $if.Clauses) {
            $hit = $clause.Item1.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                ($n.VariablePath.UserPath -match ("(^|:)" + [regex]::Escape($VarName) + "$"))
            }, $true)
            if (@($hit).Count -gt 0) { return $true }
        }
    }
    return $false
}

# True iff the function assigns $VarName and references it inside a throw.
function Test-FunctionThrowsWithVar {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$FuncAst, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Checking that '$VarName' is assigned and thrown"
    if (-not (Test-AstAssignsVar -Ast $FuncAst -VarName $VarName)) { return $false }
    $throws = $FuncAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)
    foreach ($t in $throws) {
        $ref = $t.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
            ($n.VariablePath.UserPath -match ("(^|:)" + [regex]::Escape($VarName) + "$"))
        }, $true)
        if (@($ref).Count -gt 0) { return $true }
    }
    return $false
}

# True iff the function assigns $PSNativeCommandUseErrorActionPreference = $false.
function Test-FunctionPinsNativeEap {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$FuncAst)
    $assigns = $FuncAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($a in $assigns) {
        if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (Test-VarPathIs -VariablePath $a.Left.VariablePath -Name 'PSNativeCommandUseErrorActionPreference') -and
            $a.Right.Extent.Text.Trim() -eq '$false') {
            return $true
        }
    }
    return $false
}

$rootAst   = Get-ModuleAst -Path $modulePath
$invokeWin = Get-FunctionAst -RootAst $rootAst -FunctionName 'Invoke-WinRtOcr'
$getVision = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-VisionOcrBinaryPath'

Describe 'cap-ocr-engine item 1 -- WinRT worker fallback emits a counted structured event' {
    It 'declares a module-scoped worker fallback counter' {
        Assert-True (Test-AstAssignsVar -Ast $rootAst -VarName 'WinRtOcrWorkerFallbackCount') `
            'a chronic worker fallback must be counted, not just Verbose-logged'
    }
    It 'Invoke-WinRtOcr increments the counter and emits an ocr_worker_fallback event' {
        Assert-True (Test-AstReferencesVar -Ast $invokeWin -VarName 'WinRtOcrWorkerFallbackCount') 'the fallback path touches the counter'
        Assert-True (Test-AstContainsString -Ast $invokeWin -Value 'ocr_worker_fallback') 'the fallback emits a structured event a remediator can route on'
    }
}

Describe 'cap-ocr-engine item 2 -- Vision swiftc negative cache + one-time slow-path event' {
    It 'declares a module-scoped negative-probe flag' {
        Assert-True (Test-AstAssignsVar -Ast $rootAst -VarName 'VisionOcrBinaryProbeFailed') `
            'a missing/broken swiftc must be probed once, not on every OCR poll'
    }
    It 'Get-VisionOcrBinaryPath short-circuits on the negative-probe flag' {
        Assert-True (Test-AstIfConditionOnVar -Ast $getVision -VarName 'VisionOcrBinaryProbeFailed') `
            'the flag must gate an early return so the compile is not re-attempted every poll'
    }
    It 'Get-VisionOcrBinaryPath latches the slow path via Write-VisionOcrSlowPathEvent' {
        Assert-True (Test-AstCallsCommand -Ast $getVision -CommandName 'Write-VisionOcrSlowPathEvent') `
            'swiftc-missing and compile-fail both latch the negative cache and emit the event'
    }
    It 'emits a one-time ocr_vision_slowpath event' {
        Assert-True (Test-AstContainsString -Ast $rootAst -Value 'ocr_vision_slowpath') `
            'a remediator must see macOS OCR dropped to the slow interpreter path'
    }
    It 'Clear-VisionOcrBinaryCache resets the negative-probe flag (test/env-change seam)' {
        $clr = Get-FunctionAst -RootAst $rootAst -FunctionName 'Clear-VisionOcrBinaryCache'
        Assert-True (Test-AstAssignsVar -Ast $clr -VarName 'VisionOcrBinaryProbeFailed') 'the seam must clear the negative cache'
    }
    It 'Get-VisionOcrBinaryPath pins the native-command EAP so a swiftc non-zero exit is caught, not thrown' {
        Assert-True (Test-FunctionPinsNativeEap -FuncAst $getVision) `
            'without the pin a non-zero swiftc exit throws under EAP=Stop before the compile-fail branch latches the cache'
    }
}

Describe 'cap-ocr-engine item 3 -- WinRT one-shot is EAP-guarded and diagnosable' {
    It 'Invoke-WinRtOcr pins the native-command EAP' {
        Assert-True (Test-FunctionPinsNativeEap -FuncAst $invokeWin) `
            'without the pin a non-zero powershell.exe exit throws NativeCommandExitException before the diagnostic branch on PS 7.4+'
    }
    It 'the one-shot failure detail includes stdout strings, not ErrorRecord only' {
        Assert-True (Test-FunctionThrowsWithVar -FuncAst $invokeWin -VarName 'detail') `
            'a failing powershell.exe often writes its diagnostic to stdout; an ErrorRecord-only filter throws with an empty detail'
    }
}

Describe 'ocr-hash-cache -- content-addressed temp-path hashing is centralized' {
    It 'defines a single shared source-hash-key helper' {
        Assert-True ([bool](Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-OcrSourceHashKey')) `
            'the SHA-256 -> 16-hex source-hash slice must live in one shared helper, not be inlined per call site'
    }
    It 'defines a single shared content-addressed cache helper' {
        Assert-True ([bool](Get-FunctionAst -RootAst $rootAst -FunctionName 'Resolve-CachedHashedScriptPath')) `
            'the write-if-missing + memoize temp-file cache must be shared, not copied per helper'
    }
    It 'the WinRT script-path and worker-path caches both delegate to the shared cache helper' {
        $win = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-WinRtOcrScriptPath'
        $wrk = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-WinRtOcrWorkerScriptPath'
        Assert-True (Test-AstCallsCommand -Ast $win -CommandName 'Resolve-CachedHashedScriptPath') 'Get-WinRtOcrScriptPath must delegate, not inline the cache'
        Assert-True (Test-AstCallsCommand -Ast $wrk -CommandName 'Resolve-CachedHashedScriptPath') 'Get-WinRtOcrWorkerScriptPath must delegate, not inline the cache'
    }
    It 'the shared cache helper derives its key via the shared hash helper' {
        $res = Get-FunctionAst -RootAst $rootAst -FunctionName 'Resolve-CachedHashedScriptPath'
        Assert-True (Test-AstCallsCommand -Ast $res -CommandName 'Get-OcrSourceHashKey') 'the cache helper hashes via the shared slice helper'
    }
    It 'Get-VisionOcrBinaryPath reuses the shared hash-key helper for its third copy' {
        Assert-True (Test-AstCallsCommand -Ast $getVision -CommandName 'Get-OcrSourceHashKey') `
            'the third inline hash-slice copy must reuse the shared helper'
    }
    It 'the raw SHA-256 HashData invocation appears exactly once (inside the helper)' {
        $hashCalls = $rootAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $n.Member.Value -eq 'HashData'
        }, $true)
        Assert-True (@($hashCalls).Count -eq 1) "expected exactly one SHA256::HashData call, found $(@($hashCalls).Count)"
    }
    It 'preserves the two distinct temp-file prefixes so on-disk filenames are unchanged' {
        $win = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-WinRtOcrScriptPath'
        $wrk = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-WinRtOcrWorkerScriptPath'
        Assert-True (Test-AstContainsString -Ast $win -Value 'yuruna-winrt-ocr-') 'the script path keeps its filename prefix'
        Assert-True (Test-AstContainsString -Ast $wrk -Value 'yuruna-winrt-ocr-worker-') 'the worker path keeps its filename prefix'
    }
    It 'each WinRT cache hashes its OWN source string (guards a cross-wired -Source)' {
        $win = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-WinRtOcrScriptPath'
        $wrk = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-WinRtOcrWorkerScriptPath'
        Assert-True (Test-AstReferencesVar -Ast $win -VarName 'WinRtOcrScript') 'Get-WinRtOcrScriptPath must hash $script:WinRtOcrScript'
        Assert-True (Test-AstReferencesVar -Ast $wrk -VarName 'WinRtOcrWorkerScript') 'Get-WinRtOcrWorkerScriptPath must hash $script:WinRtOcrWorkerScript'
    }
    It 'the shared cache helper keeps the .ps1 extension default so the emitted script stays -File runnable' {
        $res = Get-FunctionAst -RootAst $rootAst -FunctionName 'Resolve-CachedHashedScriptPath'
        Assert-True (Test-AstContainsString -Ast $res -Value 'ps1') 'the cached temp scripts must stay .ps1 (powershell.exe -File runs them)'
    }
}
