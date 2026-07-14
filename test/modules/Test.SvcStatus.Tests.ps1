<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a1b2c3-d4e5-4f67-8901-bd0e1f2a3b63
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status-service statusjson encoding bom pester
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
    The parent repoUrl writer in Start-StatusService.ps1 writes status.json BOM-less,
    matching the detached server and the canonical Write-YurunaStateFile sidecar encoding.
.DESCRIPTION
    A comment-proof AST guard binds the [IO.File]::WriteAllText that targets $StatusFile
    and asserts its encoding argument is a BOM-less UTF8Encoding (new($false)), so
    status.json served to the browser dashboard and the Go aggregator carries no leading
    BOM regardless of PowerShell edition (5.1's -Encoding utf8 emits a BOM). An
    encoding-semantics test confirms a BOM-less UTF8Encoding writes no BOM and round-trips,
    while utf8BOM prefixes one. Pester 4.10.1.
#>

$here = Split-Path -Parent $PSCommandPath

# Unqualified, at file scope above the Describes. An It body resolves an
# unqualified file-level variable but not a $script:-qualified one: the run pass
# re-enters the file in a fresh scope, so $script: writes land in a script scope
# the It bodies never see, and the path would arrive at the AST guard as $null.
$sss = Join-Path (Split-Path -Parent $here) 'Start-StatusService.ps1'

function Get-StatusFileWriteEncoding {
    <# Describes the encoding of the [IO.File]::WriteAllText call whose first argument
       is $StatusFile, or a sentinel when no such call is found. Returns 'bomless-utf8'
       when the third argument is [System.Text.UTF8Encoding]::new($false), otherwise the
       raw argument text (so a BOM-emitting or default-encoding write fails loudly).
       Scans the AST directly so a comment mentioning Set-Content can't fool the match. #>
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    $writes = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $n.Member.Value -eq 'WriteAllText'
    }, $true))
    foreach ($w in $writes) {
        $callArgs = @($w.Arguments)
        if ($callArgs.Count -lt 1) { continue }
        $first = $callArgs[0]
        if (-not ($first -is [System.Management.Automation.Language.VariableExpressionAst] -and
                  $first.VariablePath.UserPath -eq 'StatusFile')) { continue }
        if ($callArgs.Count -lt 3) { return '(no encoding argument)' }
        $enc = ($callArgs[2].Extent.Text -replace '\s', '')
        if ($enc -match '^\[System\.Text\.UTF8Encoding\]::new\(\$false\)$') { return 'bomless-utf8' }
        return $callArgs[2].Extent.Text
    }
    return '(no $StatusFile WriteAllText)'
}

Describe 'svc-status: the parent repoUrl writer writes status.json BOM-less' {

    Context 'source: the $StatusFile WriteAllText uses a BOM-less UTF8Encoding (AST)' {
        It 'binds [IO.File]::WriteAllText($StatusFile, ..., [UTF8Encoding]::new($false))' {
            (Get-StatusFileWriteEncoding -Path $sss) | Should -Be 'bomless-utf8'
        }
    }

    Context 'encoding semantics' {
        It 'a BOM-less UTF8Encoding writes no BOM and round-trips; utf8BOM prefixes a BOM' {
            $dir = Join-Path $env:TEMP ('svcstatus-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $doc = [pscustomobject]@{ repoUrl = 'https://example.test/x'; overallStatus = 'pass' }
                $json = $doc | ConvertTo-Json -Depth 10

                $noBom = Join-Path $dir 'nobom.json'
                [System.IO.File]::WriteAllText($noBom, $json, [System.Text.UTF8Encoding]::new($false))
                $nb = [System.IO.File]::ReadAllBytes($noBom)
                ($nb[0] -eq 0xEF -and $nb[1] -eq 0xBB -and $nb[2] -eq 0xBF) | Should -BeFalse
                (Get-Content -Raw $noBom | ConvertFrom-Json).repoUrl | Should -Be 'https://example.test/x'

                $withBom = Join-Path $dir 'withbom.json'
                $doc | ConvertTo-Json -Depth 10 | Set-Content -Path $withBom -Encoding utf8BOM
                $wb = [System.IO.File]::ReadAllBytes($withBom)
                ($wb[0] -eq 0xEF -and $wb[1] -eq 0xBB -and $wb[2] -eq 0xBF) | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
