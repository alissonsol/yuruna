<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4285ea0b-cf26-4402-b8af-aa598d20d4c0
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
    The launcher's repoUrl rewrite runs against a private status file through
    the real shared status writer. Its bytes must be BOM-less UTF-8, and the
    rewritten JSON must preserve unrelated and non-ASCII values. An encoding
    control confirms a BOM-less UTF8Encoding round-trips while utf8BOM prefixes
    a BOM. No listener, repository lookup or host operation runs.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Status.psm1') -Force -DisableNameChecking
$script:sss = Join-Path (Split-Path -Parent $here) 'service/Start-StatusService.ps1'
$ast = Get-YurunaTestFileAst -Path $script:sss
$rewrites = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '-not $RefreshSafe -and (Test-Path $StatusFile)'
}, $true))
if ($rewrites.Count -ne 1) { throw 'The launcher must contain one non-refresh repoUrl rewrite.' }
$script:RepoUrlRewrite = [scriptblock]::Create('param($StatusFile, $TestRoot, $ModulesDir, $RefreshSafe)' + "`n" + $rewrites[0].Extent.Text)

}

Describe 'svc-status: the parent repoUrl writer writes status.json BOM-less' {

    Context 'the launcher uses the shared status writer' {
        It 'rewrites repoUrl as BOM-less UTF-8 while preserving the complete JSON document' {
            function Resolve-GitRemoteLink {
                param([string]$Url)
                [pscustomobject]@{ Url = ($Url -replace '^git@github.com:', 'https://github.com/' -replace '\.git$', '') }
            }
            function Format-YurunaOperatorMessage {
                param([string]$Key, [hashtable]$Arguments)
                $null = $Arguments
                $Key
            }
            $dir = New-YurunaTestTempDir -Prefix 'svcstatus'
            try {
                $path = Join-Path $dir 'status.json'
                $description = 'caf' + [char]0xE9 + ' ' + [char]0x65E5
                $doc = @{ repoUrl = 'git@github.com:fixture/example.git'; overallStatus = 'pass'
                    guests = @(@{ name = 'vm-1'; lastFailure = @{ errorMessage = $description } }) }
                [IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($true))
                $null = & $script:RepoUrlRewrite -StatusFile $path -TestRoot $dir -ModulesDir $here -RefreshSafe $false
                $bytes = [IO.File]::ReadAllBytes($path)
                ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
                $rewritten = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
                $rewritten.repoUrl | Should -BeExactly 'https://github.com/fixture/example'
                $rewritten.overallStatus | Should -BeExactly 'pass'
                $rewritten.guests[0].name | Should -BeExactly 'vm-1'
                $rewritten.guests[0].lastFailure.errorMessage | Should -BeExactly $description
            } finally { Remove-YurunaTestTempDir $dir }
        }
    }

    Context 'encoding semantics' {
        It 'a BOM-less UTF8Encoding writes no BOM and round-trips; utf8BOM prefixes a BOM' {
            $dir = New-YurunaTestTempDir -Prefix 'svcstatus'
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
                Remove-YurunaTestTempDir $dir
            }
        }
    }
}
