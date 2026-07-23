<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42a1b2c3-d4e5-4f67-8901-ac0d1e2f3a62
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test vmutility compare-screenshot gdi dispose pester
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
    Compare-Screenshot (Test.VMUtility) releases its GDI+ source bitmaps on every path,
    including when image load / LockBits / Marshal.Copy throws, without altering the
    similarity verdict.
.DESCRIPTION
    AST guards (comment-proof, run on every platform) assert the two source bitmaps are
    disposed inside a finally, null-guarded, with no duplicate happy-path dispose of the
    reference bitmap. Behavioral tests (Windows, where System.Drawing.Bitmap is supported)
    assert the similarity verdict is unchanged and -- using the fact that a Bitmap built
    from a file path holds that file open until disposed -- prove the source files are
    released on both the success and the load-throw paths. Pester 4.10.1.
#>

$here = Split-Path -Parent $PSCommandPath

# --- REGION: Comment-proof structural guards over the source AST
function Get-CompareScreenshotAst {
    param([string]$Path)
    $errs = $null
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    $fileAst.Find({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Compare-Screenshot'
    }, $true)
}
function Get-DisposeInvocation {
    param($Ast, [string]$VarName)
    $want = $VarName
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $n.Member.Value -eq 'Dispose' -and
        $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Expression.VariablePath.UserPath -eq $want
    }, $true))
}
function Test-NodeInFinally {
    param($Node)
    $p = $Node
    while ($p) {
        $parent = $p.Parent
        if ($parent -is [System.Management.Automation.Language.TryStatementAst] -and
            $parent.Finally -and ($parent.Finally -eq $p)) { return $true }
        $p = $parent
    }
    return $false
}
function Test-DisposeNullGuarded {
    param($Node, [string]$VarName)
    $want = $VarName
    $p = $Node
    while ($p) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
            $cond = $p.Clauses[0].Item1
            $refs = @($cond.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $n.VariablePath.UserPath -eq $want
            }, $true))
            if ($refs.Count -ge 1) { return $true }
        }
        $p = $p.Parent
    }
    return $false
}

# Unqualified file-scope variables: inside an It block a $script: reference resolves to the
# test runner's own script scope, not this file's, so a $script:-qualified AST reaches the
# structural guards as $null.
$vmUtilPath = Join-Path $here 'Test.VMUtility.psm1'
$cmpAst     = Get-CompareScreenshotAst -Path $vmUtilPath

# --- REGION: Windows-only image factory (System.Drawing.Bitmap is Windows-supported)
function Get-TestPng {
    param([string]$Path, [int]$Width = 40, [int]$Height = 40, [int]$R = 0, [int]$G = 0, [int]$B = 0)
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($Width, $Height)
    # $gfx, not $g: PowerShell variable names are case-insensitive, so a local $g
    # would alias the [int]$G channel param and coerce the Graphics to Int32.
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $gfx.Clear([System.Drawing.Color]::FromArgb(255, $R, $G, $B))
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $gfx.Dispose()
        $bmp.Dispose()
    }
    return $Path
}

Describe 'ha-ca-vmutil: Compare-Screenshot releases its GDI+ bitmaps on every path' {

    Context 'structure: both source bitmaps are disposed in a finally (AST)' {
        It 'defines Compare-Screenshot' {
            $cmpAst | Should -Not -BeNullOrEmpty
        }
        It 'disposes $ref exactly once, and that dispose is inside a finally' {
            $refDisposes = Get-DisposeInvocation -Ast $cmpAst -VarName 'ref'
            $refDisposes.Count | Should -Be 1
            (Test-NodeInFinally -Node $refDisposes[0]) | Should -BeTrue
        }
        It 'disposes $ref and $act inside a finally, each null-guarded' {
            $refFinal = @(Get-DisposeInvocation -Ast $cmpAst -VarName 'ref' | Where-Object { Test-NodeInFinally -Node $_ })
            $actFinal = @(Get-DisposeInvocation -Ast $cmpAst -VarName 'act' | Where-Object { Test-NodeInFinally -Node $_ })
            $refFinal.Count | Should -BeGreaterOrEqual 1
            $actFinal.Count | Should -BeGreaterOrEqual 1
            (Test-DisposeNullGuarded -Node $refFinal[0] -VarName 'ref') | Should -BeTrue
            (Test-DisposeNullGuarded -Node $actFinal[0] -VarName 'act') | Should -BeTrue
        }
    }

    Context 'behavioral equivalence and handle release' {
        BeforeAll {
            Get-Module Test.VMUtility | Remove-Module -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $PSScriptRoot 'Test.VMUtility.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }

        It 'returns match=$true, similarity 1.0 for identical images' -Skip:(-not $IsWindows) {
            $dir = Join-Path $env:TEMP ('vmu-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $a = Get-TestPng -Path (Join-Path $dir 'a.png') -R 10 -G 120 -B 200
                $b = Get-TestPng -Path (Join-Path $dir 'b.png') -R 10 -G 120 -B 200
                $r = Compare-Screenshot -ReferencePath $a -ActualPath $b -Threshold 0.85
                $r.match      | Should -BeTrue
                $r.similarity | Should -Be 1.0
                $r.error      | Should -BeNullOrEmpty
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'returns match=$false for clearly different images' -Skip:(-not $IsWindows) {
            $dir = Join-Path $env:TEMP ('vmu-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $black = Get-TestPng -Path (Join-Path $dir 'black.png') -R 0 -G 0 -B 0
                $white = Get-TestPng -Path (Join-Path $dir 'white.png') -R 255 -G 255 -B 255
                $r = Compare-Screenshot -ReferencePath $black -ActualPath $white -Threshold 0.85
                $r.match      | Should -BeFalse
                $r.similarity | Should -BeLessThan 0.85
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'resizes a size-mismatched actual and still compares (resize branch)' -Skip:(-not $IsWindows) {
            $dir = Join-Path $env:TEMP ('vmu-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $ref = Get-TestPng -Path (Join-Path $dir 'ref.png') -Width 40 -Height 40 -R 30 -G 60 -B 90
                $act = Get-TestPng -Path (Join-Path $dir 'act.png') -Width 20 -Height 20 -R 30 -G 60 -B 90
                $r = Compare-Screenshot -ReferencePath $ref -ActualPath $act -Threshold 0.85
                $r.error | Should -BeNullOrEmpty
                $r.match | Should -BeTrue
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'reports the missing file for an absent reference or actual' -Skip:(-not $IsWindows) {
            $dir = Join-Path $env:TEMP ('vmu-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $a = Get-TestPng -Path (Join-Path $dir 'a.png') -R 1 -G 2 -B 3
                $missRef = Compare-Screenshot -ReferencePath (Join-Path $dir 'nope.png') -ActualPath $a
                $missRef.match | Should -BeFalse
                $missRef.error | Should -Be 'Reference not found'
                $missAct = Compare-Screenshot -ReferencePath $a -ActualPath (Join-Path $dir 'nope.png')
                $missAct.match | Should -BeFalse
                $missAct.error | Should -Be 'Actual not found'
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'releases both source files after a successful compare (deletable)' -Skip:(-not $IsWindows) {
            $dir = Join-Path $env:TEMP ('vmu-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $a = Get-TestPng -Path (Join-Path $dir 'a.png') -R 44 -G 88 -B 132
                $b = Get-TestPng -Path (Join-Path $dir 'b.png') -R 44 -G 88 -B 132
                $null = Compare-Screenshot -ReferencePath $a -ActualPath $b -Threshold 0.85
                # A Bitmap built from a file path holds that file open until disposed;
                # a successful delete proves both source bitmaps were released.
                { Remove-Item -LiteralPath $a -ErrorAction Stop } | Should -Not -Throw
                { Remove-Item -LiteralPath $b -ErrorAction Stop } | Should -Not -Throw
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'releases the reference file when the actual image fails to load (throw path)' -Skip:(-not $IsWindows) {
            $dir = Join-Path $env:TEMP ('vmu-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $ref     = Get-TestPng -Path (Join-Path $dir 'ref.png') -R 12 -G 34 -B 56
                $corrupt = Join-Path $dir 'corrupt.png'
                Set-Content -LiteralPath $corrupt -Value 'this is not a PNG' -Encoding ascii
                $r = Compare-Screenshot -ReferencePath $ref -ActualPath $corrupt -Threshold 0.85
                $r.match | Should -BeFalse
                $r.error | Should -Not -BeNullOrEmpty
                # The reference bitmap was created (locking ref.png) before the actual's
                # load threw; a successful delete proves the finally disposed it anyway.
                { Remove-Item -LiteralPath $ref -ErrorAction Stop } | Should -Not -Throw
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
