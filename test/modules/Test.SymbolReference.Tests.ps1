<#PSScriptInfo
.VERSION 2026.11.23
.GUID 427504bf-8d60-4048-9647-daa181e19b63
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester documentation symbols
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Every command name the documentation and the comments use still names
    something.
.DESCRIPTION
    A renamed or removed function leaves its old name in the prose that points
    readers at it. tools/Test-SymbolReference.ps1 resolves every Verb-Noun name
    in the Markdown and the PowerShell comments of each repository against the
    tree, the running PowerShell and a reviewed allow-list; this suite holds the
    repositories to it and pins the rules that keep it from crying wolf.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Tool = Join-Path $script:RepoRoot 'tools/Test-SymbolReference.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    function Get-WorkspaceSymbolRoot {
        param([Parameter(Mandatory)][string]$Repository)
        $workspace = Split-Path -Parent $Repository
        $roots = @($Repository)
        foreach ($sibling in 'yuruna-project', 'amisad.dev', 'yuruna.link') {
            $candidates = if ($sibling -ceq 'amisad.dev') {
                @($env:YURUNA_AMISAD_ROOT, (Join-Path $workspace $sibling))
            } else { @(Join-Path $workspace $sibling) }
            $selected = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ '.git')) } | Select-Object -First 1
            if ($selected) { $roots += $selected }
        }
        return $roots
    }
}

Describe 'the repositories name only commands that exist' {
    It 'resolves every command name in the docs and comments of each repository present' {
        $roots = @(Get-WorkspaceSymbolRoot -Repository $script:RepoRoot)
        $output = (& $script:Pwsh -NoProfile -NonInteractive -Command "& '$($script:Tool.Replace("'", "''"))' -Root @($(($roots | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','))" 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because $output
    }
}

Describe 'workspace sibling discovery' {
    It 'uses an explicit nonadjacent AmisAd checkout and keeps the adjacent fallback' {
        $saved = Save-YurunaTestEnvironment -Name 'YURUNA_AMISAD_ROOT'
        try {
            $workspace = Join-Path $TestDrive 'workspace'
            $framework = Join-Path $workspace 'yuruna'
            $adjacent = Join-Path $workspace 'amisad.dev'
            $explicit = Join-Path $TestDrive 'outside/amisad.dev'
            foreach ($path in $framework, $adjacent, $explicit) {
                $null = New-Item -ItemType Directory -Path (Join-Path $path '.git') -Force
            }
            $env:YURUNA_AMISAD_ROOT = $explicit
            @(Get-WorkspaceSymbolRoot -Repository $framework) | Should -Be @($framework, $explicit)
            $env:YURUNA_AMISAD_ROOT = Join-Path $TestDrive 'missing'
            @(Get-WorkspaceSymbolRoot -Repository $framework) | Should -Be @($framework, $adjacent)
            Remove-Item -LiteralPath Env:YURUNA_AMISAD_ROOT
            @(Get-WorkspaceSymbolRoot -Repository $framework) | Should -Be @($framework, $adjacent)
        } finally {
            Restore-YurunaTestEnvironment -Saved $saved
        }
    }
}

Describe 'a name the tree does not define is reported, and only that' {
    BeforeAll {
        $script:Fixture = Join-Path $TestDrive 'symbols'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'docs') -Force
        [IO.File]::WriteAllText((Join-Path $script:Fixture 'Thing.psm1'), @'
function Get-Thing { }
function script:Set-Other { }
$runtime = @"
function Invoke-Runtime { }
"@
# Calls Remove-Missing, which is gone.
'@)
        [IO.File]::WriteAllText((Join-Path $script:Fixture 'docs/guide.md'), @'
Get-Thing, Set-Other and Invoke-Runtime are defined.
The Set-Guest* family, DISM /Enable-Feature, Reset/Initialize-Status and the
Test-Start.guest.ps1 file are not command names.
Remove-Gone was renamed.
'@)
        [IO.File]::WriteAllText((Join-Path $script:Fixture 'allow.json'), '{ "schemaVersion": 1, "commands": {}, "hooks": {}, "illustrative": { "Send-Example": "an example" } }')
        $null = & git -C $script:Fixture init -q 2>&1
        $script:Run = (& $script:Pwsh -NoProfile -NonInteractive -File $script:Tool -Root $script:Fixture -AllowListPath (Join-Path $script:Fixture 'allow.json') 2>&1) -join "`n"
        $script:Exit = $LASTEXITCODE
    }
    It 'fails, naming the file and line of each unknown name' {
        $script:Exit | Should -Be 1
        $script:Run | Should -Match 'docs/guide\.md:4 Remove-Gone names nothing'
        $script:Run | Should -Match 'Thing\.psm1:6 Remove-Missing names nothing'
    }
    It 'resolves functions defined with a scope prefix or inside a here-string' {
        $script:Run | Should -Not -Match 'Set-Other|Invoke-Runtime|Get-Thing'
    }
    It 'does not read a family, a slash list, a switch or a file name as a command' {
        $script:Run | Should -Not -Match 'Set-Guest|Enable-Feature|Initialize-Status|Test-Start'
        $script:Run | Should -Match '2 unresolved name\(s\)'
    }
}
