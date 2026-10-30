<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42c6f065-60ee-4e8b-8462-a3be21141250
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester host driver source
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
    Test.DriverSource.psm1 -- how suites read a host driver that is split into a
    root module and part files.
.DESCRIPTION
    The fixture cases build a small driver under TestDrive; the last cases read
    the three real drivers, so a part that a root forgets to load, or a function
    defined twice, fails here before it misleads the suites that lift functions.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.DriverSource.psm1') -Force -DisableNameChecking

    function New-DriverFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes files under TestDrive only.')]
        param([string]$Root, [string]$Part, [string]$PartName = 'Yuruna.Host.Capture.ps1', [switch]$NoPart)
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $folder = Join-Path $repo 'host/macos.utm/modules'
        $null = New-Item -ItemType Directory -Force -Path $folder
        [IO.File]::WriteAllText((Join-Path $folder 'Yuruna.Host.psm1'), $Root)
        if (-not $NoPart) { [IO.File]::WriteAllText((Join-Path $folder $PartName), $Part) }
        return $repo
    }

    $script:PartHeader = "<#PSScriptInfo`n.VERSION 1`n#>`n`n#requires -version 7`n`n"
    $script:Root = @'
# --- REGION: Module setup
$script:Setting = 1
function Get-First { 'first' }
. (Join-Path $PSScriptRoot 'Yuruna.Host.Capture.ps1')
# --- REGION: Exports
function Get-Last { 'last' }
'@
    $script:Part = $script:PartHeader + @'
# --- REGION: Capture
function Get-Capture {
    function Get-First { 'nested helper, not the driver function' }
    'capture'
}
'@
}

Describe 'Reading a driver split into a root module and parts' {
    It 'lists the root first, then each part in the order the root loads it' {
        $repo = New-DriverFixture -Root $script:Root -Part $script:Part
        $files = @(Get-YurunaDriverFile -Driver macos.utm -RepoRoot $repo)
        $files.Count | Should -Be 2
        $files[0] | Should -BeLike '*host/macos.utm/modules/Yuruna.Host.psm1'
        $files[1] | Should -BeLike '*host/macos.utm/modules/Yuruna.Host.Capture.ps1'
    }

    It 'reads the source in the order it runs, each part without its own header' {
        $repo = New-DriverFixture -Root $script:Root -Part $script:Part
        $text = Get-YurunaDriverText -Driver macos.utm -RepoRoot $repo
        $text | Should -Not -Match 'PSScriptInfo|#requires|Join-Path \$PSScriptRoot'
        $start = $text.IndexOf('# --- REGION: Capture', [StringComparison]::Ordinal)
        $end = $text.IndexOf('# --- REGION: Exports', $start, [StringComparison]::Ordinal)
        $start | Should -BeGreaterThan $text.IndexOf('function Get-First', [StringComparison]::Ordinal)
        $end | Should -BeGreaterThan $start -Because 'a region slice that spans a moved block still finds its end marker after it'
        $text.Substring($start, $end - $start) | Should -Match 'function Get-Capture'
        (Get-YurunaDriverAst -Driver macos.utm -RepoRoot $repo).FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true).Count | Should -Be 4
    }

    It 'lifts a function from whichever file defines it, and ignores a nested helper of the same name' {
        $repo = New-DriverFixture -Root $script:Root -Part $script:Part
        Get-YurunaDriverFunction -Driver macos.utm -Name Get-Capture -RepoRoot $repo | Should -Match "'capture'"
        Get-YurunaDriverFunction -Driver macos.utm -Name Get-First -RepoRoot $repo | Should -BeExactly "function Get-First { 'first' }"
        Get-YurunaDriverFunction -Driver macos.utm -Name Get-Last -RepoRoot $repo | Should -Match "'last'"
    }

    It 'reads a driver through its root module''s path and any other file as itself' {
        $repo = New-DriverFixture -Root $script:Root -Part $script:Part
        $rootPath = Join-Path $repo 'host/macos.utm/modules/Yuruna.Host.psm1'
        Get-YurunaSourceText -Path $rootPath | Should -BeExactly (Get-YurunaDriverText -Driver macos.utm -RepoRoot $repo)
        Get-YurunaSourceFunction -Path $rootPath -Name Get-Capture | Should -Match "'capture'"
        @((Get-YurunaSourceAst -Path $rootPath).FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)).Count | Should -Be 4
        $other = Join-Path $repo 'host/macos.utm/modules/Yuruna.Host.Capture.ps1'
        Get-YurunaSourceText -Path $other | Should -BeExactly $script:Part
        Get-YurunaSourceFunction -Path $other -Name Get-Capture | Should -Match "'capture'"
        { Get-YurunaSourceFunction -Path $other -Name Get-Last } | Should -Throw -ExpectedMessage '*found 0*'
    }

    It 'gives the shared Test.Assert readers the whole driver, and re-reads it when only a part changed' {
        $repo = New-DriverFixture -Root $script:Root -Part $script:Part
        $rootPath = Join-Path $repo 'host/macos.utm/modules/Yuruna.Host.psm1'
        Get-YurunaTestSourceText -Path $rootPath | Should -BeExactly (Get-YurunaDriverText -Driver macos.utm -RepoRoot $repo)
        (Get-YurunaTestFunctionAst -Path $rootPath -Name Get-Capture) | Should -Not -BeNullOrEmpty
        $partPath = Join-Path $repo 'host/macos.utm/modules/Yuruna.Host.Capture.ps1'
        [IO.File]::WriteAllText($partPath, $script:PartHeader + "function Get-Renamed { 'renamed' }`n")
        (Get-Item -LiteralPath $partPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(1)
        (Get-YurunaTestFunctionAst -Path $rootPath -Name Get-Renamed) | Should -Not -BeNullOrEmpty -Because 'a cached parse of the root alone would miss the part''s change'
        (Get-YurunaTestFunctionAst -Path $rootPath -Name Get-Capture) | Should -BeNullOrEmpty
    }

    It 'refuses a missing function, a function defined in two files, and a part the root loads but nobody wrote' {
        $repo = New-DriverFixture -Root $script:Root -Part $script:Part
        { Get-YurunaDriverFunction -Driver macos.utm -Name Get-Absent -RepoRoot $repo } | Should -Throw -ExpectedMessage '*found 0*'
        $twice = New-DriverFixture -Root $script:Root -Part ($script:PartHeader + "function Get-Last { 'again' }`n")
        { Get-YurunaDriverFunction -Driver macos.utm -Name Get-Last -RepoRoot $twice } | Should -Throw -ExpectedMessage '*found 2*'
        $orphan = New-DriverFixture -Root $script:Root -NoPart
        { Get-YurunaDriverFile -Driver macos.utm -RepoRoot $orphan } | Should -Throw -ExpectedMessage '*part not found*'
        { Get-YurunaDriverText -Driver macos.utm -RepoRoot $orphan } | Should -Throw -ExpectedMessage '*part not found*'
    }

    It 'reads the real <Driver> driver: it parses, defines each contract verb once, and no function in two files' -ForEach @(
        @{ Driver = 'macos.utm' }, @{ Driver = 'ubuntu.kvm' }, @{ Driver = 'windows.hyper-v' }
    ) {
        $ast = Get-YurunaDriverAst -Driver $Driver
        $coverage = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-YurunaHostContractCoverage' }, $true)
        $coverage | Should -Not -BeNullOrEmpty
        $declared = $coverage.Find({ param($n) $n -is [Management.Automation.Language.ArrayLiteralAst] }, $true)
        $verbs = @($declared.Elements | ForEach-Object { $_.Value })
        $verbs.Count | Should -BeGreaterThan 30
        foreach ($verb in $verbs) { { Get-YurunaDriverFunction -Driver $Driver -Name $verb } | Should -Not -Throw -Because "$Driver declares $verb" }
        $seen = @{}
        $twice = foreach ($file in (Get-YurunaDriverFile -Driver $Driver)) {
            $fileAst = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            foreach ($statement in $fileAst.EndBlock.Statements) {
                if ($statement -isnot [Management.Automation.Language.FunctionDefinitionAst]) { continue }
                if ($seen.ContainsKey($statement.Name)) { "$($statement.Name) in $($seen[$statement.Name]) and $file" } else { $seen[$statement.Name] = $file }
            }
        }
        @($twice) | Should -BeNullOrEmpty
    }
}
