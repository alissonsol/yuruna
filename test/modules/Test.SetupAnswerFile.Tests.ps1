<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 427bf883-f57a-449e-98af-a9cec3b9704c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna setup answer-file round-trip pester
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
# Pester supplies Describe/It/Should here. Without it every one of those calls
# raises CommandNotFoundException, the engine keeps going, and the file reaches
# its end and exits 0 -- so a harness that shells this out records a PASS for a
# suite that executed no assertion at all. A test that cannot run must say so in
# its exit code; silence that reads as success is worse than no test.
BeforeAll {
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    Pester coverage for install/setup.ps1's answer-file round trip: the document
    the writer emits has to be a document the reader accepts, and the key set the
    writer emits has to be the key set the reader reads.
.DESCRIPTION
    An answer file is the only artifact setup.ps1 produces for another machine,
    and it advertises itself as such in the closing output. Nothing held the
    writer and the reader to one schema, and the file the writer emitted for a
    local-storage run carried the exact value the reader refuses.

    The two functions are lifted out of the script by AST rather than by running
    it: setup.ps1 is an orchestrator that changes the machine, and none of that
    is needed to check a schema.

    Throw-based assertions for Pester 5+.
    Run with:  Invoke-Pester -Path test/modules/Test.SetupAnswerFile.Tests.ps1
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$setupPs1 = Join-Path $repoRoot 'install/setup.ps1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# The script's own definitions, dot-sourced into this session. Anything that
# drifts in setup.ps1 drifts here on the next run, which is the point.
$parseErrors = $null
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupPs1, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "Parse errors in ${setupPs1}: $($parseErrors[0].Message)" }
foreach ($wanted in @('New-SetupAnswerDocument', 'Test-SetupAnswerSet', 'Set-SetupProjectUrl')) {
    $definition = @($setupAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "$wanted is not defined in $setupPs1" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# setup.ps1's console and log writers, replaced so the lifted function's report
# can be read back from the information stream: the console line is what the
# operator sees during the run, the log line is what a failure is diagnosed from.
function Write-SetupMessage { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '') Write-Information "console: $Message" }
function Write-SetupDetail  { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '') Write-Information "log: $Message" }

# A test.config.yml with the comments a line-level edit has to keep.
function New-SetupConfigFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes one file into a throwaway directory the calling It block deletes.')]
    [CmdletBinding()] [OutputType([string])]
    param([string]$Directory, [string]$ProjectUrl)
    $path = Join-Path $Directory 'test.config.yml'
    Set-Content -LiteralPath $path -Value @(
        '# Repositories under test; comments are most of this file''s documentation.'
        'repositories:'
        '  frameworkUrl: https://github.com/alissonsol/yuruna'
        "  projectUrl: $ProjectUrl"
        'statusService:'
        '  port: 8080'
    )
    return $path
}

# 'setup.type' etc. -- the flattened paths, so a document and a set of
# Get-Answer calls can be compared as the same kind of thing.
function Get-DocumentKeyPath {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Document, [string]$Prefix = '')
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Document.Keys) {
        $path = if ($Prefix) { "$Prefix.$key" } else { "$key" }
        if ($Document[$key] -is [System.Collections.IDictionary]) {
            foreach ($child in (Get-DocumentKeyPath -Document $Document[$key] -Prefix $path)) { $paths.Add($child) }
        } else {
            $paths.Add($path)
        }
    }
    return $paths.ToArray()
}

# Every literal path setup.ps1 asks the answer file for.
function Get-ReaderKeyPath {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Ast)
    $calls = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Answer'
    }, $true))
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($call in $calls) {
        foreach ($element in $call.CommandElements) {
            if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $element.Value -ne 'Get-Answer') {
                if (-not $paths.Contains($element.Value)) { $paths.Add($element.Value) }
            }
        }
    }
    return $paths.ToArray()
}

# Read and warned about rather than honored: an older file may still carry it,
# and the run says so instead of silently ignoring a key the operator wrote.
$script:obsoleteReaderKey = @('lab.createDefaultPool')

}

Describe 'the answer document the writer emits' {
    It 'carries exactly the keys the reader asks the file for' {
        $doc = New-SetupAnswerDocument -SetupType 'lab' -RunTests $true -ProjectUrl 'https://example.invalid/p' `
            -StorageKind 'nas' -LocalRoot '/srv/yuruna' -NetworkPath '//ypool-nas/work/yuruna.pool' `
            -NetworkUser 'yuruna-pool' -OnFailure 'local' -LabName 'workshop'
        $written = @(Get-DocumentKeyPath -Document $doc) | Sort-Object
        $read    = @(Get-ReaderKeyPath -Ast $setupAst | Where-Object { $_ -notin $script:obsoleteReaderKey }) | Sort-Object
        Assert-Equal -Expected ($read -join ', ') -Actual ($written -join ', ') -Because 'the writer and the reader must agree on the key set'
    }
    It 'omits the lab section for a standalone setup' {
        $doc = New-SetupAnswerDocument -SetupType 'standalone' -RunTests $false -StorageKind 'local' `
            -LocalRoot '/srv/yuruna' -OnFailure 'stop'
        Assert-True (-not $doc.Contains('lab')) 'a standalone answer file has no lab section'
    }
}


Describe 'a document the writer emits is one the validator accepts' {
    It 'round-trips every (setup.type, storage.kind, storage.onFailure) combination' {
        $roundTripCase = @(
            @{ Type = 'standalone'; Kind = 'local'; OnFailure = 'stop';  Root = '/srv/yuruna'; Path = '';  User = '';  Lab = '' }
            @{ Type = 'standalone'; Kind = 'local'; OnFailure = 'local'; Root = '/srv/yuruna'; Path = '';  User = '';  Lab = '' }
            @{ Type = 'standalone'; Kind = 'none';  OnFailure = 'stop';  Root = '';            Path = '';  User = '';  Lab = '' }
            @{ Type = 'standalone'; Kind = 'nas';   OnFailure = 'stop';  Root = '';            Path = '//ypool-nas/work/yuruna.pool'; User = 'yuruna-pool'; Lab = '' }
            @{ Type = 'standalone'; Kind = 'nas';   OnFailure = 'local'; Root = '/srv/yuruna'; Path = '//ypool-nas/work/yuruna.pool'; User = 'yuruna-pool'; Lab = '' }
            @{ Type = 'lab';        Kind = 'local'; OnFailure = 'stop';  Root = '/srv/yuruna'; Path = '';  User = '';  Lab = 'workshop' }
            @{ Type = 'lab';        Kind = 'nas';   OnFailure = 'local'; Root = '/srv/yuruna'; Path = '//ypool-nas/work/yuruna.pool'; User = 'yuruna-pool'; Lab = 'workshop' }
        )
        Assert-Equal 7 $roundTripCase.Count 'all supported combinations are exercised'
        foreach ($case in $roundTripCase) {
            $doc = New-SetupAnswerDocument -SetupType $case.Type -RunTests $true -ProjectUrl '' `
                -StorageKind $case.Kind -LocalRoot $case.Root -NetworkPath $case.Path `
                -NetworkUser $case.User -OnFailure $case.OnFailure -LabName $case.Lab
            $problems = @(Test-SetupAnswerSet -SetupType $doc.setup.type -StorageKind $doc.storage.kind `
                -LocalRoot $doc.storage.localRoot -NetworkPath $doc.storage.networkPath `
                -NetworkUser $doc.storage.networkUser -OnFailure $doc.storage.onFailure `
                -LabName $(if ($doc.Contains('lab')) { $doc.lab.name } else { '' }))
            Assert-Equal -Expected 0 -Actual $problems.Count -Because ("the writer emitted a document its own reader rejects for " +
                "$($case.Type)/$($case.Kind)/onFailure $($case.OnFailure): $($problems -join '; ')")
        }
    }
}

Describe 'the validator refuses what an unattended run cannot finish' {
    It 'rejects kind local with an empty localRoot' {
        # The one pairing where an emitted file is worse than no file at all: a
        # blank root is what a run that never resolved one has to serialize, and
        # it is also the value the reader refuses. Caught here, the writer is
        # forced to warn; missed, the file is advertised for the next machine and
        # that machine stops at the storage step.
        $doc = New-SetupAnswerDocument -SetupType 'standalone' -RunTests $true -StorageKind 'local' `
            -LocalRoot '' -OnFailure 'stop'
        $problems = @(Test-SetupAnswerSet -SetupType $doc.setup.type -StorageKind $doc.storage.kind `
            -LocalRoot $doc.storage.localRoot -OnFailure $doc.storage.onFailure)
        Assert-Equal -Expected 1 -Actual $problems.Count -Because 'exactly one problem, naming storage.localRoot'
        Assert-True ($problems[0] -like '*storage.localRoot*') "the message must name the key: $($problems[0])"
    }
    It 'rejects a lab with no storage' {
        $problems = @(Test-SetupAnswerSet -SetupType 'lab' -StorageKind 'none' -OnFailure 'stop' -LabName 'workshop')
        Assert-True (@($problems | Where-Object { $_ -like "*'none' is not valid for a lab*" }).Count -eq 1) 'a lab needs shared storage'
    }
    It 'rejects a lab with no name' {
        $problems = @(Test-SetupAnswerSet -SetupType 'lab' -StorageKind 'local' -LocalRoot '/srv/yuruna' -OnFailure 'stop')
        Assert-True (@($problems | Where-Object { $_ -like '*lab.name*' }).Count -eq 1) 'a lab needs a name'
    }
    It 'rejects nas with a missing account' {
        $problems = @(Test-SetupAnswerSet -SetupType 'standalone' -StorageKind 'nas' `
            -NetworkPath '//ypool-nas/work/yuruna.pool' -NetworkUser '' -OnFailure 'stop')
        Assert-True (@($problems | Where-Object { $_ -like '*networkUser*' }).Count -eq 1) 'a NAS needs both keys'
    }
    It 'rejects unknown kind and onFailure values, naming each key' {
        $problems = @(Test-SetupAnswerSet -SetupType 'standalone' -StorageKind 'cloud' -OnFailure 'maybe')
        Assert-Equal -Expected 2 -Actual $problems.Count -Because 'one problem per bad key'
        Assert-True (@($problems | Where-Object { $_ -like '*storage.kind*' }).Count -eq 1) 'names storage.kind'
        Assert-True (@($problems | Where-Object { $_ -like '*storage.onFailure*' }).Count -eq 1) 'names storage.onFailure'
    }
    It 'accepts a NAS run with no localRoot' {
        # A NAS that mounts never needs the key, so requiring it up front would
        # refuse a run that was going to be fine.
        $problems = @(Test-SetupAnswerSet -SetupType 'standalone' -StorageKind 'nas' `
            -NetworkPath '//ypool-nas/work/yuruna.pool' -NetworkUser 'yuruna-pool' -OnFailure 'local')
        Assert-Equal -Expected 0 -Actual $problems.Count -Because 'the fallback carries its own check at the point it is reached'
    }
}

Describe 'projectUrl in test.config.yml across setup runs' {
    # An operator who points projectUrl at their own project repository and
    # re-runs setup without an answer file must find it untouched. A setup that
    # replaces it with the built-in default while printing only the new value
    # sends the cycles that follow to the wrong project with every check green,
    # so the console line for a real replacement names both values.
    It 'keeps a project URL the operator set when setup runs again with its built-in default' {
        $d = New-YurunaTestTempDir -Prefix 'yrn-setup-url'
        try {
            $cfg = New-SetupConfigFile -Directory $d -ProjectUrl 'file:///Users/operator/git/amisad.dev'
            $before = Get-Content -Raw -LiteralPath $cfg
            $report = $null
            $r = Set-SetupProjectUrl -ConfigPath $cfg -ProjectUrl 'https://github.com/alissonsol/yuruna-project' -InformationVariable report
            Assert-Equal -Expected 'kept' -Actual $r.Outcome -Because 'the default never replaces a value already there'
            Assert-Equal -Expected 'file:///Users/operator/git/amisad.dev' -Actual $r.Current -Because 'the operator value stands'
            Assert-StringEqual -Expected $before -Actual (Get-Content -Raw -LiteralPath $cfg) -Because 'the file was not rewritten'
            $lines = @($report | ForEach-Object { "$($_.MessageData)" })
            Assert-Equal -Expected 1 -Actual @($lines | Where-Object { $_ -match '^log: projectUrl kept as file:///Users/operator/git/amisad\.dev ' }).Count -Because 'the log says what was kept and how to change it'
            Assert-Equal -Expected 0 -Actual @($lines | Where-Object { $_ -match '->' }).Count -Because 'nothing was replaced, so no replacement is reported'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reports previous -> new on the console when an answer file replaces the operator value' {
        $d = New-YurunaTestTempDir -Prefix 'yrn-setup-url'
        try {
            $cfg = New-SetupConfigFile -Directory $d -ProjectUrl 'file:///Users/operator/git/amisad.dev'
            $report = $null
            $r = Set-SetupProjectUrl -ConfigPath $cfg -ProjectUrl 'https://example/other-project' -FromAnswerFile -InformationVariable report
            Assert-Equal -Expected 'replaced' -Actual $r.Outcome -Because 'a value the operator supplied for this run wins'
            Assert-Equal -Expected 'file:///Users/operator/git/amisad.dev' -Actual $r.Previous -Because 'previous value returned'
            $after = @(Get-Content -LiteralPath $cfg)
            Assert-Equal -Expected '  projectUrl: https://example/other-project' -Actual $after[3] -Because 'the line was replaced in place'
            Assert-Equal -Expected '# Repositories under test; comments are most of this file''s documentation.' -Actual $after[0] -Because 'comments survive the edit'
            $console = @($report | ForEach-Object { "$($_.MessageData)" } | Where-Object { $_ -like 'console: *' })
            Assert-Equal -Expected 1 -Actual $console.Count -Because 'a replacement reaches the operator''s screen, not only the log'
            Assert-Match '^console: projectUrl: file:///Users/operator/git/amisad\.dev -> https://example/other-project ' $console[0] 'the line names the value that was replaced, never only the new one'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'fills a blank key with the default and says it was blank' {
        $d = New-YurunaTestTempDir -Prefix 'yrn-setup-url'
        try {
            $cfg = New-SetupConfigFile -Directory $d -ProjectUrl '""'
            $report = $null
            $r = Set-SetupProjectUrl -ConfigPath $cfg -ProjectUrl 'https://github.com/alissonsol/yuruna-project' -InformationVariable report
            Assert-Equal -Expected 'filled' -Actual $r.Outcome -Because 'the default fills a blank'
            Assert-Equal -Expected '  projectUrl: https://github.com/alissonsol/yuruna-project' -Actual @(Get-Content -LiteralPath $cfg)[3] -Because 'blank replaced on disk'
            $lines = @($report | ForEach-Object { "$($_.MessageData)" })
            Assert-Equal -Expected 1 -Actual @($lines | Where-Object { $_ -eq 'log: projectUrl: (blank) -> https://github.com/alissonsol/yuruna-project' }).Count -Because 'the log records that nothing was lost'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'leaves the file alone when the answer file names the value already there' {
        $d = New-YurunaTestTempDir -Prefix 'yrn-setup-url'
        try {
            $cfg = New-SetupConfigFile -Directory $d -ProjectUrl 'https://example/other-project'
            $before = Get-Content -Raw -LiteralPath $cfg
            $r = Set-SetupProjectUrl -ConfigPath $cfg -ProjectUrl 'https://example/other-project' -FromAnswerFile -InformationAction SilentlyContinue
            Assert-Equal -Expected 'kept' -Actual $r.Outcome -Because 'same value, nothing to replace'
            Assert-StringEqual -Expected $before -Actual (Get-Content -Raw -LiteralPath $cfg) -Because 'the file was not rewritten'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'refuses a file with no projectUrl key instead of guessing where to add one' {
        $d = New-YurunaTestTempDir -Prefix 'yrn-setup-url'
        try {
            $cfg = Join-Path $d 'test.config.yml'
            Set-Content -LiteralPath $cfg -Value @('repositories:', '  frameworkUrl: https://github.com/alissonsol/yuruna')
            Assert-Throw { Set-SetupProjectUrl -ConfigPath $cfg -ProjectUrl 'https://example/p' -InformationAction SilentlyContinue } 'no projectUrl key found' 'a missing key is an error, not a silent no-op'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
