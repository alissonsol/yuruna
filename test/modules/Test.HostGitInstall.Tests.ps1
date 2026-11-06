<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42b667c7-9705-40d2-b7ab-42c08bffb2a3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostgit install pester
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
    Structural Pester guard on test/modules/Test.HostGit.psm1: the PSGallery
    module-install policy is shared by one helper, not duplicated across the two
    Install-*IfMissing bootstrappers.
.DESCRIPTION
    Install-PowerShellYamlIfMissing and Install-PSScriptAnalyzerIfMissing had
    byte-identical bodies (Get-Module early return / ShouldProcess WhatIf gate /
    Install-Module -Scope CurrentUser -Force -AllowClobber / catch-warn) differing
    only in the module-name string. These AST guards assert the policy is now in
    one Install-YurunaGalleryModuleIfMissing helper, both wrappers delegate, the
    raw Install-Module call appears exactly once, and the helper stays private.
    AST/source-only. Runs under Pester 5.x (script-scoped throw helper).

    The host installers and tools/Install-TestModule.ps1 each carry their own
    copy of the pin they install from (each runs alone, before the harness
    modules are usable); the last group keeps every copy equal to the table in
    Test.HostGit.psm1, so one drifting pin fails here.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.HostGit.psm1'
$script:helper     = 'Install-YurunaGalleryModuleIfMissing'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-ModuleAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    return Get-YurunaTestFileAst -Path $Path
}

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)]$RootAst, [Parameter(Mandatory)][string]$FunctionName)
    $found = Get-YurunaTestFunctionAst -Ast $RootAst -Name $FunctionName
    if (-not $found) { throw "Function $FunctionName not found" }
    return $found
}

function Test-AstCallsCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    return ((Get-YurunaTestCommandCallCount -Ast $Ast -CommandName $CommandName) -gt 0)
}

function Get-CommandCallCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    return (Get-YurunaTestCommandCallCount -Ast $Ast -CommandName $CommandName)
}

$rootAst = Get-ModuleAst -Path $modulePath

}

Describe 'hostgit-install -- the PSGallery install policy is shared by one helper' {
    It 'defines an Install-YurunaGalleryModuleIfMissing helper' {
        $found = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $script:helper
        }, $true)
        Assert-True (@($found).Count -eq 1) 'the two byte-identical install bodies must collapse into one helper'
    }
    It 'both Install-*IfMissing wrappers delegate to the shared helper' {
        $yaml = Get-FunctionAst -RootAst $rootAst -FunctionName 'Install-PowerShellYamlIfMissing'
        $psa  = Get-FunctionAst -RootAst $rootAst -FunctionName 'Install-PSScriptAnalyzerIfMissing'
        Assert-True (Test-AstCallsCommand -Ast $yaml -CommandName $script:helper) 'Install-PowerShellYamlIfMissing must delegate to the shared policy'
        Assert-True (Test-AstCallsCommand -Ast $psa -CommandName $script:helper) 'Install-PSScriptAnalyzerIfMissing must delegate to the shared policy'
    }
    It 'installs only pinned, digest-checked packages, never through an unpinned Install-Module' {
        $n = Get-CommandCallCount -Ast $rootAst -CommandName 'Install-Module'
        Assert-True ($n -eq 0) "Install-Module resolves whatever the gallery serves; found $n call(s)"
        $helperAst = Get-FunctionAst -RootAst $rootAst -FunctionName $script:helper
        Assert-True (Test-AstCallsCommand -Ast $helperAst -CommandName 'Install-YurunaGalleryPackage') 'the helper installs through the verified package installer'
    }
    It 'the helper stays private; both public wrappers remain exported' {
        $exportCalls = $rootAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true)
        Assert-True (@($exportCalls).Count -ge 1) 'Export-ModuleMember must be present'
        $exportText = ($exportCalls | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -notmatch [regex]::Escape($script:helper)) 'the shared policy helper must not be exported'
        Assert-True ($exportText -match 'Install-PowerShellYamlIfMissing') 'Install-PowerShellYamlIfMissing must remain exported'
        Assert-True ($exportText -match 'Install-PSScriptAnalyzerIfMissing') 'Install-PSScriptAnalyzerIfMissing must remain exported'
    }
}

Describe 'hostgit-install -- a gallery module is installed only from the pinned, verified package' {
    BeforeAll {
        Import-Module (Join-Path $repoRoot 'test/modules/Test.HostGit.psm1') -Force -DisableNameChecking

        # A package laid out the way the gallery serves one: the module files plus
        # the NuGet packaging entries PowerShellGet leaves out of the module.
        function New-FixturePackage {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a throwaway package under TestDrive.')]
            param([string]$Path, [hashtable]$Entry)
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
            try {
                foreach ($name in $Entry.Keys) {
                    $writer = [IO.StreamWriter]::new($zip.CreateEntry($name).Open())
                    try { $writer.Write($Entry[$name]) } finally { $writer.Dispose() }
                }
            } finally { $zip.Dispose() }
            $sha = [Security.Cryptography.SHA512]::Create()
            try { return [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) } finally { $sha.Dispose() }
        }
        $script:FixtureEntries = @{
            'yuruna-fixture.psd1'            = "@{ ModuleVersion = '1.2.3'; RootModule = 'yuruna-fixture.psm1' }"
            'yuruna-fixture.psm1'            = 'function Get-Fixture { 1 }'
            'yuruna-fixture.nuspec'          = '<package/>'
            '[Content_Types].xml'            = '<Types/>'
            '_rels/.rels'                    = '<Relationships/>'
            'package/services/metadata/x.ps' = 'meta'
        }
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Package = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.nupkg')
    }

    It 'refuses a package whose SHA-512 differs from the pin and installs nothing' {
        $null = New-FixturePackage -Path $script:Package -Entry $script:FixtureEntries
        InModuleScope Test.HostGit -Parameters @{ Package = $script:Package; Root = $script:Root } {
            param($Package, $Root)
            $script:YurunaGalleryModulePin['yuruna-fixture'] = @{ Version = '1.2.3'; Sha512 = ('A' * 86) + '==' }
            $script:FixturePackagePath = $Package
            $script:FixtureModuleRoot = $Root
            Mock Get-YurunaGalleryPackage { Copy-Item -LiteralPath $script:FixturePackagePath -Destination $OutFile }
            Mock Get-YurunaUserModuleRoot { $script:FixtureModuleRoot }
            Mock Write-Warning { }
            try {
                Install-YurunaGalleryModuleIfMissing -Name 'yuruna-fixture' -Confirm:$false | Should -BeFalse
                Should -Invoke Get-YurunaGalleryPackage -Times 1 -Exactly
                Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*SHA-512*does not match the pinned digest*' }
                Test-Path -LiteralPath (Join-Path $Root 'yuruna-fixture') | Should -BeFalse
            } finally { $script:YurunaGalleryModulePin.Remove('yuruna-fixture') }
        }
    }

    It 'installs a matching package as Name/Version without the NuGet packaging entries' {
        $digest = New-FixturePackage -Path $script:Package -Entry $script:FixtureEntries
        InModuleScope Test.HostGit -Parameters @{ Package = $script:Package; Root = $script:Root; Digest = $digest } {
            param($Package, $Root, $Digest)
            $script:YurunaGalleryModulePin['yuruna-fixture'] = @{ Version = '1.2.3'; Sha512 = $Digest }
            $script:FixturePackagePath = $Package
            $script:FixtureModuleRoot = $Root
            Mock Get-YurunaGalleryPackage { Copy-Item -LiteralPath $script:FixturePackagePath -Destination $OutFile }
            Mock Get-YurunaUserModuleRoot { $script:FixtureModuleRoot }
            try {
                Install-YurunaGalleryModuleIfMissing -Name 'yuruna-fixture' -Confirm:$false 6>$null | Should -BeTrue
                $installed = @(Get-ChildItem -LiteralPath (Join-Path $Root 'yuruna-fixture') -Recurse -File -Force |
                        ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') } | Sort-Object)
                $installed | Should -Be @('yuruna-fixture/1.2.3/yuruna-fixture.psd1', 'yuruna-fixture/1.2.3/yuruna-fixture.psm1')
            } finally { $script:YurunaGalleryModulePin.Remove('yuruna-fixture') }
        }
    }

    It 'refuses a package entry that would land outside the module directory' {
        $entries = $script:FixtureEntries.Clone()
        $entries['../escaped.ps1'] = 'outside'
        $null = New-FixturePackage -Path $script:Package -Entry $entries
        InModuleScope Test.HostGit -Parameters @{ Package = $script:Package; Root = $script:Root } {
            param($Package, $Root)
            $thrown = $null
            try { Install-YurunaGalleryPackage -PackagePath $Package -Name 'yuruna-fixture' -Version '1.2.3' -ModuleRoot $Root -Confirm:$false }
            catch { $thrown = $_ }
            "$thrown" | Should -BeLike '*escapes the module directory*'
            Test-Path -LiteralPath (Join-Path $Root 'yuruna-fixture/escaped.ps1') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $Root 'yuruna-fixture/1.2.3') | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Join-Path $Root 'yuruna-fixture') -Force) | Should -HaveCount 0
        }
    }

}

Describe 'hostgit-install -- every installer copy of a pin equals the host''s' {
    BeforeAll {
        Import-Module (Join-Path $repoRoot 'test/modules/Test.HostGit.psm1') -Force -DisableNameChecking
        $script:HostPin = InModuleScope Test.HostGit { $script:YurunaGalleryModulePin }

        function Get-ShellYamlBlock {
            # The pin lines through the pwsh call that installs from them.
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$Installer)
            $text = Get-Content -LiteralPath (Join-Path $repoRoot $Installer) -Raw
            $match = [regex]::Match($text, '(?ms)^POWERSHELL_YAML_VERSION=.*?^'' \|\| note_issue "[^\n]*\n')
            if (-not $match.Success) { throw "$Installer carries no powershell-yaml pin block" }
            return $match.Value
        }
        function Get-PowerShellPin {
            # One row of a pin table written the way Test.HostGit.psm1 writes its own.
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
            $text = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
            $match = [regex]::Match($text, "(?m)^\s*'$([regex]::Escape($Name))'\s*=\s*@\{ Version = '([^']+)'; Sha512 = '([^']+)' \}")
            if (-not $match.Success) { throw "$Path carries no $Name pin" }
            return @{ Version = $match.Groups[1].Value; Sha512 = $match.Groups[2].Value }
        }
    }

    It 'keeps the shell installer''s powershell-yaml pin equal to the host''s (<Installer>)' -ForEach @(
        @{ Installer = 'install/macos.utm.sh' }, @{ Installer = 'install/ubuntu.kvm.sh' }
    ) {
        $installer = Get-Content -LiteralPath (Join-Path $repoRoot $Installer) -Raw
        ([regex]::Match($installer, '(?m)^POWERSHELL_YAML_VERSION="([^"]+)"')).Groups[1].Value | Should -BeExactly $script:HostPin['powershell-yaml'].Version
        ([regex]::Match($installer, '(?m)^POWERSHELL_YAML_SHA512="([^"]+)"')).Groups[1].Value | Should -BeExactly $script:HostPin['powershell-yaml'].Sha512
        $installer | Should -Not -Match 'Install-Module -Name powershell-yaml -Scope CurrentUser -Force'
    }

    It 'the shell installers install powershell-yaml through one block' {
        # Each runs alone from a one-line download, so the block is duplicated by
        # necessity; this keeps the copies from drifting apart.
        Get-ShellYamlBlock -Installer 'install/ubuntu.kvm.sh' | Should -BeExactly (Get-ShellYamlBlock -Installer 'install/macos.utm.sh')
    }

    It 'keeps the Windows installer''s powershell-yaml pin equal to the host''s' {
        $pin = Get-PowerShellPin -Path 'install/windows.hyper-v.ps1' -Name 'powershell-yaml'
        $pin.Version | Should -BeExactly $script:HostPin['powershell-yaml'].Version
        $pin.Sha512 | Should -BeExactly $script:HostPin['powershell-yaml'].Sha512
        $ast = Get-YurunaTestFileAst -Path (Join-Path $repoRoot 'install/windows.hyper-v.ps1')
        Get-YurunaTestCommandCallCount -Ast $ast -CommandName 'Install-Module' | Should -Be 0
    }

    It 'keeps Install-TestModule.ps1''s PSScriptAnalyzer pin equal to the host''s' {
        $pin = Get-PowerShellPin -Path 'tools/Install-TestModule.ps1' -Name 'PSScriptAnalyzer'
        $pin.Version | Should -BeExactly $script:HostPin['PSScriptAnalyzer'].Version
        $pin.Sha512 | Should -BeExactly $script:HostPin['PSScriptAnalyzer'].Sha512
        # Pester is the one module requested by its line (the newest 6.x) rather
        # than by a pin, so Install-Module appears once, inside that install.
        $ast = Get-YurunaTestFileAst -Path (Join-Path $repoRoot 'tools/Install-TestModule.ps1')
        Get-YurunaTestCommandCallCount -Ast $ast -CommandName 'Install-Module' | Should -Be 1
        $pester = Get-YurunaTestFunctionAst -Ast $ast -Name 'Install-NewestPester'
        Get-YurunaTestCommandCallCount -Ast $pester -CommandName 'Install-Module' | Should -Be 1
    }

    It 'the Windows installer and Install-TestModule.ps1 install a pinned package through one function' {
        $copies = foreach ($path in 'install/windows.hyper-v.ps1', 'tools/Install-TestModule.ps1') {
            $found = Get-YurunaTestFunctionAst -Path (Join-Path $repoRoot $path) -Name 'Install-YurunaPinnedGalleryModule'
            if (-not $found) { throw "$path carries no Install-YurunaPinnedGalleryModule" }
            $found.Extent.Text.Replace("`r`n", "`n")
        }
        $copies[1] | Should -BeExactly $copies[0]
    }
}
