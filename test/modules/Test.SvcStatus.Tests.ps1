<#PSScriptInfo
.VERSION 2026.07.10
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
    A comment-proof AST guard binds the Set-Content that targets $StatusFile and asserts
    its -Encoding is BOM-less utf8 (not utf8BOM), so status.json served to the browser
    dashboard and the Go aggregator carries no leading BOM. An encoding-semantics test
    confirms utf8 writes no BOM and round-trips, while utf8BOM prefixes one. Pester 4.10.1.
#>

$here = Split-Path -Parent $PSCommandPath
$script:sss = Join-Path (Split-Path -Parent $here) 'Start-StatusService.ps1'

function Get-StatusFileEncoding {
    <# Returns the -Encoding argument text of the Set-Content whose -Path is $StatusFile,
       or a sentinel when no such command is found. Scans the command elements directly
       (comment-proof; the StaticParameterBinder does not surface -Encoding for this cmdlet). #>
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    $setContent = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-Content'
    }, $true))
    foreach ($c in $setContent) {
        $els = $c.CommandElements
        $targetsStatusFile = $false
        foreach ($e in $els) {
            if ($e -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $e.VariablePath.UserPath -eq 'StatusFile') { $targetsStatusFile = $true }
        }
        if (-not $targetsStatusFile) { continue }
        for ($i = 0; $i -lt $els.Count; $i++) {
            $e = $els[$i]
            if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and
                $e.ParameterName -eq 'Encoding') {
                if ($e.Argument) { return $e.Argument.Extent.Text }
                if ($i + 1 -lt $els.Count) { return $els[$i + 1].Extent.Text }
            }
        }
        return '(no -Encoding)'
    }
    return '(no $StatusFile Set-Content)'
}

Describe 'svc-status: the parent repoUrl writer writes status.json BOM-less' {

    Context 'source: the $StatusFile Set-Content uses BOM-less utf8 (AST)' {
        It 'binds Set-Content -Path $StatusFile -Encoding utf8 (not utf8BOM)' {
            (Get-StatusFileEncoding -Path $script:sss) | Should -Be 'utf8'
        }
    }

    Context 'encoding semantics' {
        It 'utf8 writes no BOM and round-trips; utf8BOM prefixes a BOM' {
            $dir = Join-Path $env:TEMP ('svcstatus-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                $doc = [pscustomobject]@{ repoUrl = 'https://example.test/x'; overallStatus = 'pass' }

                $noBom = Join-Path $dir 'nobom.json'
                $doc | ConvertTo-Json -Depth 10 | Set-Content -Path $noBom -Encoding utf8
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
