<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42ad2307-9a03-4f84-a1e4-d45e7d08db4d
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

    Throw-based assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
    Run with:  Invoke-Pester -Path test/modules/Test.SetupAnswerFile.Tests.ps1
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$setupPs1 = Join-Path $repoRoot 'install/setup.ps1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# The script's own definitions, dot-sourced into this session. Anything that
# drifts in setup.ps1 drifts here on the next run, which is the point.
$parseErrors = $null
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupPs1, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "Parse errors in ${setupPs1}: $($parseErrors[0].Message)" }
foreach ($wanted in @('New-SetupAnswerDocument', 'Test-SetupAnswerSet')) {
    $definition = @($setupAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "$wanted is not defined in $setupPs1" }
    . ([scriptblock]::Create($definition.Extent.Text))
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

# Read and warned about rather than honoured: an older file may still carry it,
# and the run says so instead of silently ignoring a key the operator wrote.
$obsoleteReaderKey = @('lab.createDefaultPool')

Describe 'the answer document the writer emits' {
    It 'carries exactly the keys the reader asks the file for' {
        $doc = New-SetupAnswerDocument -SetupType 'lab' -RunTests $true -ProjectUrl 'https://example.invalid/p' `
            -StorageKind 'nas' -LocalRoot '/srv/yuruna' -NetworkPath '//ypool-nas/work/yuruna.pool' `
            -NetworkUser 'yuruna-pool' -OnFailure 'local' -LabName 'workshop'
        $written = @(Get-DocumentKeyPath -Document $doc) | Sort-Object
        $read    = @(Get-ReaderKeyPath -Ast $setupAst | Where-Object { $_ -notin $obsoleteReaderKey }) | Sort-Object
        Assert-Equal ($read -join ', ') ($written -join ', ') 'the writer and the reader must agree on the key set'
    }
    It 'omits the lab section for a standalone setup' {
        $doc = New-SetupAnswerDocument -SetupType 'standalone' -RunTests $false -StorageKind 'local' `
            -LocalRoot '/srv/yuruna' -OnFailure 'stop'
        Assert-True (-not $doc.Contains('lab')) 'a standalone answer file has no lab section'
    }
}

# Every combination the writer can produce. At file scope and iterated INSIDE the
# It below rather than around it: a Describe body runs during the discovery pass,
# so cases built there and closed over by generated It blocks resolve differently
# across Pester editions.
$roundTripCase = @(
    @{ Type = 'standalone'; Kind = 'local'; OnFailure = 'stop';  Root = '/srv/yuruna'; Path = '';  User = '';  Lab = '' }
    @{ Type = 'standalone'; Kind = 'local'; OnFailure = 'local'; Root = '/srv/yuruna'; Path = '';  User = '';  Lab = '' }
    @{ Type = 'standalone'; Kind = 'none';  OnFailure = 'stop';  Root = '';            Path = '';  User = '';  Lab = '' }
    @{ Type = 'standalone'; Kind = 'nas';   OnFailure = 'stop';  Root = '';            Path = '//ypool-nas/work/yuruna.pool'; User = 'yuruna-pool'; Lab = '' }
    @{ Type = 'standalone'; Kind = 'nas';   OnFailure = 'local'; Root = '/srv/yuruna'; Path = '//ypool-nas/work/yuruna.pool'; User = 'yuruna-pool'; Lab = '' }
    @{ Type = 'lab';        Kind = 'local'; OnFailure = 'stop';  Root = '/srv/yuruna'; Path = '';  User = '';  Lab = 'workshop' }
    @{ Type = 'lab';        Kind = 'nas';   OnFailure = 'local'; Root = '/srv/yuruna'; Path = '//ypool-nas/work/yuruna.pool'; User = 'yuruna-pool'; Lab = 'workshop' }
)

Describe 'a document the writer emits is one the validator accepts' {
    It 'round-trips every (setup.type, storage.kind, storage.onFailure) combination' {
        foreach ($case in $roundTripCase) {
            $doc = New-SetupAnswerDocument -SetupType $case.Type -RunTests $true -ProjectUrl '' `
                -StorageKind $case.Kind -LocalRoot $case.Root -NetworkPath $case.Path `
                -NetworkUser $case.User -OnFailure $case.OnFailure -LabName $case.Lab
            $problems = @(Test-SetupAnswerSet -SetupType $doc.setup.type -StorageKind $doc.storage.kind `
                -LocalRoot $doc.storage.localRoot -NetworkPath $doc.storage.networkPath `
                -NetworkUser $doc.storage.networkUser -OnFailure $doc.storage.onFailure `
                -LabName $(if ($doc.Contains('lab')) { $doc.lab.name } else { '' }))
            Assert-Equal 0 $problems.Count ("the writer emitted a document its own reader rejects for " +
                "$($case.Type)/$($case.Kind)/onFailure $($case.OnFailure): $($problems -join '; ')")
        }
    }
}

Describe 'the validator refuses what an unattended run cannot finish' {
    It 'rejects kind local with an empty localRoot' {
        # The one pairing where an emitted file is worse than no file at all: a
        # blank root is what a run that never resolved one has to serialise, and
        # it is also the value the reader refuses. Caught here, the writer is
        # forced to warn; missed, the file is advertised for the next machine and
        # that machine stops at the storage step.
        $doc = New-SetupAnswerDocument -SetupType 'standalone' -RunTests $true -StorageKind 'local' `
            -LocalRoot '' -OnFailure 'stop'
        $problems = @(Test-SetupAnswerSet -SetupType $doc.setup.type -StorageKind $doc.storage.kind `
            -LocalRoot $doc.storage.localRoot -OnFailure $doc.storage.onFailure)
        Assert-Equal 1 $problems.Count 'exactly one problem, naming storage.localRoot'
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
        Assert-Equal 2 $problems.Count 'one problem per bad key'
        Assert-True (@($problems | Where-Object { $_ -like '*storage.kind*' }).Count -eq 1) 'names storage.kind'
        Assert-True (@($problems | Where-Object { $_ -like '*storage.onFailure*' }).Count -eq 1) 'names storage.onFailure'
    }
    It 'accepts a NAS run with no localRoot' {
        # A NAS that mounts never needs the key, so requiring it up front would
        # refuse a run that was going to be fine.
        $problems = @(Test-SetupAnswerSet -SetupType 'standalone' -StorageKind 'nas' `
            -NetworkPath '//ypool-nas/work/yuruna.pool' -NetworkUser 'yuruna-pool' -OnFailure 'local')
        Assert-Equal 0 $problems.Count 'the fallback carries its own check at the point it is reached'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
