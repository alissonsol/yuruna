<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42d5a706-d0d1-4156-aee4-d0f84a00a06d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload sequence save pester
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
    Pester guard on Test.WorkloadSequenceFile.psm1, the YAML of an authored
    step and the sequence file a workload session saves.
.DESCRIPTION
    A saved file replays with no agent, so it must read back as exactly the
    steps that ran, pass the schema and the metadata gate, plan through the
    resolver, never land outside the framework's test/sequences, never replace
    a file another writer created, and never carry a resolved secret. The cases
    pin the name and resource rules, the documented layout, the scalar writer,
    the journal split and exclusions, the variable overlay, the generated
    sequenceGuid, the hard-link publish under concurrency and every way a save
    is refused without leaving a file behind.

    Every case builds its own framework layout under $TestDrive with copies of
    the framework's phrase and snippet libraries, the two sequences a chain
    needs, and the sequence schema. The secret check is a global stub.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceResolve.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequencePlanner.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.WorkloadRuntime.psm1') -Global -DisableNameChecking
    # The cases read a saved file as the metadata gate and the schema check do.
    Import-Module (Join-Path $PSScriptRoot '../../tools/Source.Identity.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.LocalizationExchange.psm1') -Global -DisableNameChecking
    $script:FrameworkRoot = Get-YurunaTestRepoRoot -SuiteDirectory $PSScriptRoot
    $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE'
    # The user's git configuration must not reach the fixture repository, and a
    # hook that runs this suite must not point git at its own index.
    $script:EmptyGitConfig = Join-Path $TestDrive 'empty-gitconfig'
    [IO.File]::WriteAllText($script:EmptyGitConfig, '')
    $env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    foreach ($entry in 'GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE') { Remove-Item -LiteralPath "Env:$entry" -ErrorAction SilentlyContinue }

    # A registered secret in a fixture is this text; the real filter is not loaded.
    function global:Test-SequenceSecretText {
        param([AllowEmptyString()][AllowNull()][string]$Text)
        return ([string]$Text).Contains('fixture-registered-secret', [StringComparison]::Ordinal)
    }
    Import-Module (Join-Path $PSScriptRoot 'Test.WorkloadSequenceFile.psm1') -Force -DisableNameChecking

    $script:FixtureNumber = 0
    $script:Refusals = [Collections.Generic.List[object]]::new()
    $script:RealRefusal = Get-Command New-WorkloadRefusal -CommandType Function
    $script:Prefix = 'workload.guest.ubuntu.server.24.'

    function New-SequenceFileFixture {
        <#
        .SYNOPSIS
            A fresh framework layout and a session hashtable for one save.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a fixture folder under TestDrive.')]
        param()
        $script:FixtureNumber++
        $root = Join-Path $TestDrive ('layout{0:D2}' -f $script:FixtureNumber)
        $sequences = Join-Path $root 'test/sequences'
        $null = New-Item -ItemType Directory -Path $sequences, (Join-Path $root 'test/schemas'), (Join-Path $root 'project/example/website/test'), (Join-Path $root 'session') -Force
        foreach ($file in '_phrases.yml', '_snippets.yml', 'start.guest.ubuntu.server.24.yml', 'workload.guest.ubuntu.server.24.yml') {
            Copy-Item -LiteralPath (Join-Path $script:FrameworkRoot "test/sequences/$file") -Destination $sequences
        }
        Copy-Item -LiteralPath (Join-Path $script:FrameworkRoot 'test/schemas/sequence.schema.yml') -Destination (Join-Path $root 'test/schemas')
        $runtime = Join-Path $root 'test/status/runtime'
        return @{
            SessionId          = 'fixture'
            Folder             = (Join-Path $root 'session')
            HostType           = 'host.ubuntu.kvm'
            GuestKey           = 'guest.ubuntu.server.24'
            OsKey              = 'ubuntu.server.24'
            VMName             = 'test-guest.ubuntu.server.24-01'
            RepoRoot           = $root
            TestRoot           = (Join-Path $root 'test')
            SequencesDir       = $sequences
            ConfigPath         = (Join-Path $root 'test/test.config.yml')
            Config             = @{}
            RuntimeDir         = $runtime
            StatusPath         = (Join-Path $runtime 'status.json')
            CycleStartUtc      = $null
            CycleNumber        = $null
            CycleFolder        = $null
            SourceSequence     = ''
            SourceSequencePath = ''
            SourceVariables    = [ordered]@{}
            OverrideVariables  = @{}
            State              = 'attached'
            DetachReason       = ''
            ReplayCounter      = 0
            ActiveReplay       = $null
        }
    }

    function New-JournalFixtureEntry {
        <#
        .SYNOPSIS
            One journal entry in the shape the session module writes.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Returns a value; changes nothing.')]
        param(
            [Parameter(Mandatory)][int]$Seq,
            [Parameter(Mandatory)][System.Collections.IDictionary]$Authored,
            [string]$Tool = 'workload_step',
            [string]$Outcome = 'passed',
            [string]$Effect = 'applied',
            [bool]$Runnable = $true
        )
        return [ordered]@{
            schema      = 'yuruna.workload-journal/v1'
            seq         = $Seq
            operationId = "op-$Seq"
            tool        = $Tool
            outcome     = $Outcome
            runnable    = $Runnable
            authored    = $Authored
            effect      = $Effect
        }
    }

    function Get-SentenceFixtureStep {
        <#
        .SYNOPSIS
            An authored sentence step: step, on, the timeout when given, description.
        #>
        param([Parameter(Mandatory)][string]$Sentence, [Parameter(Mandatory)][string]$Intent, [long]$Timeout = 0)
        $authored = [ordered]@{ step = $Sentence; on = 'screen' }
        if ($Timeout -gt 0) { $authored['timeoutSeconds'] = $Timeout }
        $authored['description'] = $Intent
        return $authored
    }

    function Get-DefaultFixtureJournal {
        <#
        .SYNOPSIS
            Two runnable entries: a sentence and an action.
        #>
        return , @(
            (New-JournalFixtureEntry -Seq 1 -Authored (Get-SentenceFixtureStep -Sentence "wait for text 'Welcome to Ubuntu'" -Intent 'The shell greets the user' -Timeout 60))
            (New-JournalFixtureEntry -Seq 2 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = 'systemctl is-active nginx'; description = 'The web server is active' }))
        )
    }

    function Invoke-FixtureSave {
        <#
        .SYNOPSIS
            Save-WorkloadSequenceFile with the defaults of this suite.
        #>
        param(
            [Parameter(Mandatory)][hashtable]$Session,
            [object[]]$Entry,
            [string]$Suffix = 'check',
            [string]$FullName = '',
            [string]$Text = 'Saved by the sequence-file suite.',
            [AllowEmptyCollection()][string[]]$Prerequisite = @('start.guest.ubuntu.server.24'),
            [int]$Split = 0
        )
        if ($null -eq $Entry) { $Entry = Get-DefaultFixtureJournal }
        $sequenceName = if ($FullName) { $FullName } else { $script:Prefix + $Suffix }
        return (Save-WorkloadSequenceFile -Session $Session -Journal $Entry -Name $sequenceName -Description $Text -Resource $Prerequisite -ComponentCount $Split)
    }

    function Get-FixtureTempFile {
        <#
        .SYNOPSIS
            The temporary candidates left in a sequence folder.
        #>
        param([Parameter(Mandatory)][string]$Folder)
        return , @(Get-ChildItem -LiteralPath $Folder -File -Filter '*.tmp' -ErrorAction SilentlyContinue)
    }
}

AfterAll {
    Remove-Item -LiteralPath function:\Test-SequenceSecretText -ErrorAction SilentlyContinue
    Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
}

Describe 'the name, the folder and the resource list' {
    BeforeEach {
        $script:Refusals.Clear()
        Mock New-WorkloadRefusal -ModuleName Test.WorkloadSequenceFile { $script:Refusals.Add($Arguments); & $script:RealRefusal @PesterBoundParameters }
    }

    It 'accepts and rejects sequence names' {
        $session = New-SequenceFileFixture
        foreach ($accepted in @('workload.guest.ubuntu.server.24.check', 'workload.guest.ubuntu.server.24.a-b.c1', 'workload.guest.ubuntu.server.24.login.ssh')) {
            $result = Invoke-FixtureSave -Session $session -FullName $accepted
            Assert-True ($result.ok -eq $true) "'$accepted' was refused with $($result.error.code)"
        }
        $refused = @(
            'workload.guest.ubuntu.server.24.Check'
            'workload.guest.ubuntu.server.24/check'
            'workload.guest.ubuntu.server.24..check'
            '.workload.guest.ubuntu.server.24.check'
            ('workload.guest.ubuntu.server.24.' + ('a' * 69))
            'workload.guest.ubuntu.server.26.check'
            'workload.guest.ubuntu.server.24.check.yml'
            'workload.guest.ubuntu.server.24.check.ubuntu.kvm'
            "workload.guest.ubuntu.server.24.check`n"
        )
        Assert-Equal 101 $refused[4].Length
        foreach ($rejected in $refused) {
            $result = Invoke-FixtureSave -Session $session -FullName $rejected
            Assert-StringEqual 'workload_name_invalid' $result.error.code "'$rejected'"
        }
    }

    It 'writes to the framework folder and refuses one that resolves outside the checkout' {
        $session = New-SequenceFileFixture
        $result = Invoke-FixtureSave -Session $session -Suffix 'inside'
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        Assert-StringEqual 'test/sequences/workload.guest.ubuntu.server.24.inside.yml' $result.path
        Assert-True (Test-Path -LiteralPath (Join-Path $session.SequencesDir 'workload.guest.ubuntu.server.24.inside.yml') -PathType Leaf)

        $linked = New-SequenceFileFixture
        $outside = Join-Path $TestDrive "outside$($script:FixtureNumber)"
        Move-Item -LiteralPath $linked.SequencesDir -Destination $outside
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $linked.SequencesDir -Value $outside
        $refusal = Invoke-FixtureSave -Session $linked -Suffix 'outside'
        Assert-StringEqual 'workload_folder_outside' $refusal.error.code
        Assert-False (Test-Path -LiteralPath (Join-Path $outside 'workload.guest.ubuntu.server.24.outside.yml')) 'a file was written outside'
    }

    It 'refuses a name that exists in any search folder, including every host variant' {
        $session = New-SequenceFileFixture
        $project = Join-Path $session.RepoRoot 'project/example/website/test'
        $base = 'workload.guest.ubuntu.server.24.taken'
        $occupied = @(
            (Join-Path $session.SequencesDir "$base.yml")
            (Join-Path $session.SequencesDir "$base.windows.hyper-v.yml")
            (Join-Path $project "$base.yml")
            (Join-Path $project "$base.ubuntu.kvm.yml")
            (Join-Path $project "$base.windows.hyper-v.yml")
            (Join-Path $project "$base.macos.utm.yml")
        )
        foreach ($path in $occupied) {
            [IO.File]::WriteAllText($path, "other: file`n")
            $result = Invoke-FixtureSave -Session $session -FullName $base
            Assert-StringEqual 'workload_name_exists' $result.error.code "'$path' did not block the name"
            Assert-StringEqual $path $script:Refusals[-1].path
            Remove-Item -LiteralPath $path
        }
    }

    It 'writes the resource list under the session''s OS key' {
        $session = New-SequenceFileFixture
        $result = Invoke-FixtureSave -Session $session -Suffix 'two-prerequisites' -Prerequisite @('start.guest.ubuntu.server.24', 'workload.guest.ubuntu.server.24')
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        $text = [IO.File]::ReadAllText($result.absolutePath)
        Assert-True ($text.Contains("resource:`n  ubuntu.server.24:`n    - `"start.guest.ubuntu.server.24`"`n    - `"workload.guest.ubuntu.server.24`"`n", [StringComparison]::Ordinal)) $text
        Assert-True ($text.Contains("`nkeystrokeMechanism: gui`n", [StringComparison]::Ordinal)) 'a name without .ssh is not gui'
        $ssh = Invoke-FixtureSave -Session $session -Suffix 'remote.ssh'
        Assert-True ($ssh.ok -eq $true) "the ssh save was refused with $($ssh.error.code)"
        Assert-True ([IO.File]::ReadAllText($ssh.absolutePath).Contains("`nkeystrokeMechanism: ssh`n", [StringComparison]::Ordinal)) 'a name ending in .ssh is not ssh'
    }

    It 'refuses <Case> as workload_resource_invalid' -ForEach @(
        @{ Case = 'an empty list'; Names = @() }
        @{ Case = 'seventeen names'; Names = @(1..17 | ForEach-Object { 'start.guest.ubuntu.server.24' }) }
        @{ Case = 'a name with a space'; Names = @('start guest') }
        @{ Case = 'a name with a path separator'; Names = @('test/start.guest.ubuntu.server.24') }
        @{ Case = 'a name of 121 characters'; Names = @('s' * 121) }
        @{ Case = 'a valid name ending in a line feed'; Names = @("start.guest.ubuntu.server.24`n") }
    ) {
        $session = New-SequenceFileFixture
        $result = Invoke-FixtureSave -Session $session -Suffix 'resource' -Prerequisite ([string[]]$Names)
        Assert-StringEqual 'workload_resource_invalid' $result.error.code
        Assert-False (Test-Path -LiteralPath (Join-Path $session.SequencesDir 'workload.guest.ubuntu.server.24.resource.yml')) 'a file was written'
        Assert-Equal 0 (Get-FixtureTempFile -Folder $session.SequencesDir).Count
    }

    It 'refuses a description of 201 characters or of two lines' {
        $session = New-SequenceFileFixture
        foreach ($intent in @(('d' * 201), "first line`nsecond line", '')) {
            $result = Invoke-FixtureSave -Session $session -Suffix 'description' -Text $intent
            Assert-StringEqual 'workload_argument_invalid' $result.error.code "description of length $($intent.Length)"
            Assert-StringEqual 'description' $script:Refusals[-1].name
        }
    }
}

Describe 'the text a step and a file are written as' {
    It 'writes the documented layout' {
        $session = New-SequenceFileFixture
        $session.SourceVariables = [ordered]@{ username = 'yuuser24' }
        $journal = @(
            (New-JournalFixtureEntry -Seq 1 -Authored (Get-SentenceFixtureStep -Sentence 'login ${username} with password ${ext:authentication.GetPassword(${username})}' -Intent 'Log in as the test user'))
            (New-JournalFixtureEntry -Seq 2 -Authored (Get-SentenceFixtureStep -Sentence "wait for text 'Welcome to Ubuntu'" -Intent 'The shell greets the user' -Timeout 60))
            (New-JournalFixtureEntry -Seq 3 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = 'systemctl is-active nginx'; description = 'The web server is active' }))
        )
        $result = Invoke-FixtureSave -Session $session -Entry $journal -Suffix 'layout' -Text 'Ubuntu Server 24.04: log in and confirm the web server is active.' -Split 1
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        $actual = [IO.File]::ReadAllText($result.absolutePath)
        $actual = $actual.Replace($result.sequenceGuid, 'GUID') -replace '2019-\d{4} by', '2019-YEAR by'
        $expected = @'
# yaml-language-server: $schema=../schemas/sequence.schema.yml

# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-YEAR by Alisson Sol et al.

sequenceGuid: GUID
sequenceRevision: 1

description: "Ubuntu Server 24.04: log in and confirm the web server is active."
keystrokeMechanism: gui

# --- REGION: resource
resource:
  ubuntu.server.24:
    - "start.guest.ubuntu.server.24"
variables:
  username: "yuuser24"

# --- REGION: component
component:
  - step: "login ${username} with password ${ext:authentication.GetPassword(${username})}"
    on: screen
    description: "Log in as the test user"

# --- REGION: workload
workload:
  - step: "wait for text 'Welcome to Ubuntu'"
    on: screen
    timeoutSeconds: 60
    description: "The shell greets the user"
  - action: sshExec
    command: "systemctl is-active nginx"
    description: "The web server is active"

'@ -replace "`r`n", "`n"
        Assert-True ([string]::Equals($expected, $actual, [StringComparison]::Ordinal)) "the file is:`n$actual"
    }

    It 'keeps step text and variable expressions through a parse' {
        $texts = @(
            'say "hi" and ''bye'''
            'back\slash and \"quoted\"'
            '${ext:a.B(${c})}'
            'key: value'
            'value #not a comment'
            '-leading dash'
            'yes'
            'null'
            '123'
            "tab`there"
            "line`nfeed"
            ('next' + [char]0x85 + 'line')
            ('line' + [char]0x2028 + 'separator')
            ('delete' + [char]0x7F + 'char')
            "caf`u{e9} `u{5916}"
        )
        foreach ($sample in $texts) {
            $lines = ConvertTo-WorkloadStepText -Step ([ordered]@{ action = 'sshExec'; command = $sample; description = 'parse check' }) -Indent 0
            $yaml = ($lines -join "`n") + "`n"
            Assert-False ($yaml -match '[^\x00-\x7F]') "the text of '$sample' is not ASCII"
            $parsed = ConvertFrom-Yaml -Yaml $yaml -Ordered
            $item = @($parsed)[0]
            Assert-True ($item.command -is [string]) "'$sample' did not read back as a string"
            Assert-True ([string]::Equals($sample, $item.command, [StringComparison]::Ordinal)) "'$sample' read back as '$($item.command)'"
        }
    }

    It 'writes integers, decimals, doubles and booleans so they read back equal' {
        $samples = [ordered]@{
            small    = 300
            large    = [long]4294967296
            fraction = [decimal]2.50
            whole    = [double]300
            half     = [double]2.5
            flagOn   = $true
            flagOff  = $false
        }
        Assert-StringEqual '300' (ConvertTo-WorkloadYamlScalar -Value ([double]300))
        $step = [ordered]@{ action = 'sshExec'; command = 'true' }
        foreach ($key in $samples.Keys) { $step[$key] = $samples[$key] }
        $yaml = ((ConvertTo-WorkloadStepText -Step $step -Indent 0) -join "`n") + "`n"
        $parsed = ConvertFrom-Yaml -Yaml $yaml -Ordered
        $item = @($parsed)[0]
        foreach ($key in $samples.Keys) {
            if ($samples[$key] -is [bool]) {
                Assert-True ($item[$key] -is [bool] -and $item[$key] -eq $samples[$key]) "$key read back as '$($item[$key])'"
            } else {
                Assert-True ([decimal]$item[$key] -eq [decimal]$samples[$key]) "$key read back as '$($item[$key])'"
            }
        }
        $session = New-SequenceFileFixture
        $journal = @(New-JournalFixtureEntry -Seq 1 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = 'true'; timeoutSeconds = [double]300; description = 'numbers' }))
        $result = Invoke-FixtureSave -Session $session -Entry $journal -Suffix 'numbers'
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
    }

    It 'refuses a value of another type as value-type' {
        foreach ($sample in @([double]1e20, [double]1.5e-5, [double]::NaN, [double]::PositiveInfinity, [datetime]::new(2026, 1, 1), [guid]::Empty)) {
            Assert-Throw { $null = ConvertTo-WorkloadYamlScalar -Value $sample } '' "a $($sample.GetType().Name) $sample was written"
        }
        Assert-Throw { $null = ConvertTo-WorkloadYamlScalar -Value $null } '' 'a null was written'
        $script:Refusals.Clear()
        Mock New-WorkloadRefusal -ModuleName Test.WorkloadSequenceFile { $script:Refusals.Add($Arguments); & $script:RealRefusal @PesterBoundParameters }
        $session = New-SequenceFileFixture
        $journal = @(New-JournalFixtureEntry -Seq 1 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = 'true'; timeoutSeconds = [double]1e20; description = 'too large' }))
        $result = Invoke-FixtureSave -Session $session -Entry $journal -Suffix 'value-type'
        Assert-StringEqual 'workload_candidate_invalid' $result.error.code
        Assert-StringEqual 'value-type' $script:Refusals[-1].check
    }
}

Describe 'a saved file as the gates and the runner read it' {
    BeforeAll {
        $script:GateSession = New-SequenceFileFixture
        $script:GateSession.SourceVariables = [ordered]@{ username = 'yuuser24' }
        $script:GateResult = Invoke-FixtureSave -Session $script:GateSession -Suffix 'gate-check' -Split 1
        $script:GateText = if ($script:GateResult.ok) { [IO.File]::ReadAllText($script:GateResult.absolutePath) } else { '' }
    }

    It 'the saved file reads through Read-SequenceFile and plans through Resolve-NamedSequenceChain' {
        Assert-True ($script:GateResult.ok -eq $true) "the save was refused with $($script:GateResult.error.code)"
        $read = Read-SequenceFile -Path $script:GateResult.absolutePath -NoCache
        Assert-True ($read.Contains('baseline') -and $read.baseline.Contains('ubuntu.server.24')) 'the file has no chain for the OS key'
        $chain = Resolve-NamedSequenceChain -RepoRoot $script:GateSession.RepoRoot -SequencesDir $script:GateSession.SequencesDir -HostType 'host.ubuntu.kvm' `
            -SequenceName 'workload.guest.ubuntu.server.24.gate-check' -OsKey 'ubuntu.server.24'
        Assert-StringEqual 'start.guest.ubuntu.server.24,workload.guest.ubuntu.server.24.gate-check' (@($chain.fullChain) -join ',')
    }

    It 'the saved file carries the header facts the metadata gate reads' {
        $fact = Get-SourceHeaderFact -Style hash -Line @($script:GateText.Split("`n") | Select-Object -First 40) -RelativePath 'test/sequences/workload.guest.ubuntu.server.24.gate-check.yml'
        Assert-True $fact.Copyright 'no copyright line'
        Assert-True $fact.Pointer 'no license pointer above the copyright line'
        Assert-True $fact.GuestSequence 'not read as a guest sequence'
        Assert-True ($fact.SequenceGuid -ceq $script:GateResult.sequenceGuid) "sequenceGuid '$($fact.SequenceGuid)'"
        Assert-Null $fact.LineGuid
        Assert-Equal 0 $fact.StrayGuidLine
    }

    It 'passes tools/Test-SourceMetadata.ps1 -Staged in a fixture repository' {
        $repository = New-YurunaTestGitRepository -Path (Join-Path $TestDrive 'metadata/yuruna') -CommitMessage 'seed'
        $target = Join-Path $repository 'test/sequences/workload.guest.ubuntu.server.24.gate-check.yml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        [IO.File]::WriteAllText($target, $script:GateText, [Text.UTF8Encoding]::new($false))
        $null = Invoke-YurunaTestGit -Path $repository -Argument @('add', '-A')
        $exemptions = Join-Path $TestDrive 'metadata-exemptions.json'
        [IO.File]::WriteAllText($exemptions, '{ "schema": "yuruna.source-metadata/v1" }')
        $tool = Join-Path $script:FrameworkRoot 'tools/Test-SourceMetadata.ps1'
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $tool -Staged -Root $repository -ExemptionsPath $exemptions 2>&1 | ForEach-Object { [string]$_ } | Out-String
        Assert-Equal 0 $LASTEXITCODE $output
    }

    It 'the saved file is valid against sequence.schema.yml' {
        $schema = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText((Join-Path $script:FrameworkRoot 'test/schemas/sequence.schema.yml'))) -Ordered | ConvertTo-Json -Depth 32
        $document = ConvertFrom-Yaml -Yaml $script:GateText -Ordered | ConvertTo-Json -Depth 32
        Assert-Null (Get-YurunaJsonSchemaError -Json $document -Schema $schema)
    }

    It 'has the region lines Test.SourceConsistency.Tests.ps1 requires' {
        $lines = $script:GateText.Split("`n")
        Assert-Equal 3 @($lines | Where-Object { $_.StartsWith('# --- REGION:') }).Count
        foreach ($key in 'resource', 'component', 'workload') {
            $at = [array]::FindIndex($lines, [Predicate[string]] { param($line) $line -match "^${key}:" })
            Assert-True ($at -gt 0) "no top-level $key"
            Assert-StringEqual "# --- REGION: $key" $lines[$at - 1]
        }
    }
}

Describe 'which steps a save writes' {
    It 'splits the journal once into component then workload and keeps the order' {
        $session = New-SequenceFileFixture
        $journal = @(1..4 | ForEach-Object {
                New-JournalFixtureEntry -Seq $_ -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = "echo step-$_"; description = "Step $_" })
            })
        $result = Invoke-FixtureSave -Session $session -Entry $journal -Suffix 'split' -Split 1
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        Assert-Equal 4 $result.steps
        Assert-Equal 1 $result.componentSteps
        Assert-Equal 3 $result.workloadSteps
        $document = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($result.absolutePath)) -Ordered
        Assert-StringEqual 'echo step-1' (@($document.component | ForEach-Object { $_.command }) -join ',')
        Assert-StringEqual 'echo step-2,echo step-3,echo step-4' (@($document.workload | ForEach-Object { $_.command }) -join ',')
        foreach ($split in @(-1, 5)) {
            $refused = Invoke-FixtureSave -Session $session -Entry $journal -Suffix "split-$($split + 2)" -Split $split
            Assert-StringEqual 'workload_split_invalid' $refused.error.code "componentSteps $split"
        }
    }

    It 'leaves out failed, canceled and replay entries and lists them' {
        $session = New-SequenceFileFixture
        $journal = @(
            (New-JournalFixtureEntry -Seq 1 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = 'echo kept-1'; description = 'Kept' }))
            (New-JournalFixtureEntry -Seq 2 -Outcome 'failed' -Effect 'uncertain' -Runnable $false -Authored (Get-SentenceFixtureStep -Sentence 'click button Next' -Intent 'Failed'))
            (New-JournalFixtureEntry -Seq 3 -Outcome 'canceled' -Effect 'none-proven' -Runnable $false -Authored (Get-SentenceFixtureStep -Sentence 'click button Back' -Intent 'Canceled'))
            (New-JournalFixtureEntry -Seq 4 -Tool 'workload_run_sequence' -Outcome 'passed' -Effect 'applied' -Runnable $false -Authored ([ordered]@{ sequence = 'workload.guest.ubuntu.server.24' }))
            (New-JournalFixtureEntry -Seq 5 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = 'echo kept-5'; description = 'Kept too' }))
        )
        $result = Invoke-FixtureSave -Session $session -Entry $journal -Suffix 'excluded'
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        Assert-Equal 2 $result.steps
        Assert-StringEqual '2,3,4' (@($result.excluded | ForEach-Object { $_.seq }) -join ',')
        Assert-StringEqual 'workload_step,workload_step,workload_run_sequence' (@($result.excluded | ForEach-Object { $_.tool }) -join ',')
        Assert-StringEqual 'failed,canceled,passed' (@($result.excluded | ForEach-Object { $_.outcome }) -join ',')
        Assert-StringEqual 'uncertain,none-proven,applied' (@($result.excluded | ForEach-Object { $_.effect }) -join ',')
        Assert-StringEqual 'op-2,op-3,op-4' (@($result.excluded | ForEach-Object { $_.operationId }) -join ',')
        $text = [IO.File]::ReadAllText($result.absolutePath)
        Assert-False ($text.Contains('click button', [StringComparison]::Ordinal)) 'an excluded step was written'
        $empty = Invoke-FixtureSave -Session $session -Entry @($journal[1], $journal[2], $journal[3]) -Suffix 'nothing'
        Assert-StringEqual 'workload_journal_empty' $empty.error.code
    }

    It 'writes explicit surfaces and the intent as description' {
        $session = New-SequenceFileFixture
        $journal = @(
            (New-JournalFixtureEntry -Seq 1 -Authored (Get-SentenceFixtureStep -Sentence 'expect text Welcome' -Intent 'The greeting is shown'))
            (New-JournalFixtureEntry -Seq 2 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = 'uptime'; description = 'The guest answers' }))
        )
        $result = Invoke-FixtureSave -Session $session -Entry $journal -Suffix 'surfaces'
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        $document = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($result.absolutePath)) -Ordered
        $steps = @($document.workload)
        Assert-StringEqual 'screen' $steps[0].on
        Assert-StringEqual 'The greeting is shown' $steps[0].description
        Assert-False ($steps[1].Contains('on')) 'an action step has a surface'
        Assert-StringEqual 'The guest answers' $steps[1].description
    }

    It 'takes the variables of the source sequence and the overrides, not those of its prerequisites, and drops null values' {
        $session = New-SequenceFileFixture
        $session.SourceVariables = [ordered]@{ username = 'yuuser24'; port = '8080'; dropped = $null; retries = 3 }
        $session.OverrideVariables = [ordered]@{ port = '9090'; extra = 'added' }
        $result = Invoke-FixtureSave -Session $session -Suffix 'variables'
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        $document = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($result.absolutePath)) -Ordered
        Assert-StringEqual 'username,port,retries,extra' (@($document.variables.Keys) -join ',')
        Assert-StringEqual '9090' $document.variables.port
        Assert-Equal 3 $document.variables.retries
        Assert-False ($document.variables.Contains('currentPassword')) 'a variable of the prerequisite was written'
    }

    It 'generates a sequenceGuid no other sequence file declares' {
        $session = New-SequenceFileFixture
        $script:TakenGuid = ([regex]::Match([IO.File]::ReadAllText((Join-Path $session.SequencesDir 'start.guest.ubuntu.server.24.yml')), 'sequenceGuid:\s*([0-9a-f-]{36})')).Groups[1].Value
        Assert-Match '^[0-9a-f-]{36}$' $script:TakenGuid
        $fresh = '42abcdef-0000-4000-8000-000000000001'
        $script:GuidDraws = [Collections.Generic.List[string]]::new()
        $script:GuidAnswers = [Collections.Generic.Queue[string]]::new()
        $script:GuidAnswers.Enqueue($script:TakenGuid)
        $script:GuidAnswers.Enqueue($fresh)
        Mock New-SourceGuid -ModuleName Test.WorkloadSequenceFile { $next = $script:GuidAnswers.Dequeue(); $script:GuidDraws.Add($next); $next }
        $result = Invoke-FixtureSave -Session $session -Suffix 'guid'
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        Assert-StringEqual $fresh $result.sequenceGuid
        Assert-Equal 2 $script:GuidDraws.Count

        $script:Refusals.Clear()
        $script:GuidDraws.Clear()
        Mock New-WorkloadRefusal -ModuleName Test.WorkloadSequenceFile { $script:Refusals.Add($Arguments); & $script:RealRefusal @PesterBoundParameters }
        Mock New-SourceGuid -ModuleName Test.WorkloadSequenceFile { $script:GuidDraws.Add($script:TakenGuid); $script:TakenGuid }
        $collided = Invoke-FixtureSave -Session $session -Suffix 'guid-collision'
        Assert-StringEqual 'workload_candidate_invalid' $collided.error.code
        Assert-StringEqual 'guid' $script:Refusals[-1].check
        Assert-Equal 8 $script:GuidDraws.Count
    }

    It 'saves a round that opens with an sshWaitReady action and splits after two steps' {
        $session = New-SequenceFileFixture
        $journal = @(
            (New-JournalFixtureEntry -Seq 1 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshWaitReady'; timeoutSeconds = [long]300; description = 'Wait for sshd before the page check' }))
            (New-JournalFixtureEntry -Seq 2 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshFetchAndExecute'; command = 'echo ready'; timeoutSeconds = [long]120; description = 'Prepare the page check' }))
            (New-JournalFixtureEntry -Seq 3 -Authored (Get-SentenceFixtureStep -Sentence 'wait for text Welcome' -Intent 'The console greets'))
            (New-JournalFixtureEntry -Seq 4 -Authored (Get-SentenceFixtureStep -Sentence 'expect text Welcome' -Intent 'The greeting stays'))
        )
        $result = Invoke-FixtureSave -Session $session -Entry $journal -FullName 'workload.guest.ubuntu.server.24.page-authoring-check.ssh' `
            -Prerequisite @('workload.guest.ubuntu.server.24') -Split 2
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        Assert-Equal 2 $result.componentSteps
        Assert-Equal 2 $result.workloadSteps
        $text = [IO.File]::ReadAllText($result.absolutePath)
        Assert-True ($text.Contains("`nkeystrokeMechanism: ssh`n", [StringComparison]::Ordinal)) 'the file is not ssh'
        Assert-True ($text.Contains("component:`n  - action: sshWaitReady`n    timeoutSeconds: 300`n    description: `"Wait for sshd before the page check`"`n", [StringComparison]::Ordinal)) $text
        $read = Read-SequenceFile -Path $result.absolutePath -NoCache
        Assert-StringEqual 'sshWaitReady' @($read.steps)[0].action
    }
}

Describe 'publishing a file' {
    It 'of eight simultaneous publishes of one name exactly one succeeds' {
        $folder = Join-Path $TestDrive 'parallel'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $modulePath = Join-Path $PSScriptRoot 'Test.WorkloadSequenceFile.psm1'
        $barrier = [Threading.Barrier]::new(8)
        $rows = 1..8 | ForEach-Object -ThrottleLimit 8 -Parallel {
            $worker = $_
            $gate = $using:barrier
            $target = $using:folder
            Import-Module $using:modulePath -DisableNameChecking
            for ($round = 1; $round -le 50; $round++) {
                $temp = Join-Path $target ('round{0:D2}.yml.{1}-{2}.tmp' -f $round, $worker, [guid]::NewGuid().ToString('N'))
                [IO.File]::WriteAllText($temp, "round $round worker $worker`n")
                $final = Join-Path $target ('round{0:D2}.yml' -f $round)
                if (-not $gate.SignalAndWait(60000)) { throw "round $round did not start together" }
                $outcome = Publish-WorkloadSequenceFile -TempPath $temp -FinalPath $final
                [pscustomobject]@{ Round = $round; Worker = $worker; Published = $outcome.Published; Reason = $outcome.Reason }
            }
        }
        $barrier.Dispose()
        Assert-Equal 400 @($rows).Count
        for ($round = 1; $round -le 50; $round++) {
            $winners = @($rows | Where-Object { $_.Round -eq $round -and $_.Published })
            Assert-Equal 1 $winners.Count "round $round had $($winners.Count) winners"
            $losers = @($rows | Where-Object { $_.Round -eq $round -and -not $_.Published })
            Assert-StringEqual 'exists,exists,exists,exists,exists,exists,exists' (@($losers | ForEach-Object { $_.Reason }) -join ',') "round $round"
            $content = [IO.File]::ReadAllText((Join-Path $folder ('round{0:D2}.yml' -f $round)))
            Assert-StringEqual "round $round worker $($winners[0].Worker)`n" $content "round $round"
        }
    }

    It 'never replaces an existing file, a dangling link or a directory at the final name' {
        $folder = Join-Path $TestDrive 'occupied'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $file = Join-Path $folder 'file.yml'
        [IO.File]::WriteAllText($file, 'original')
        $dangling = Join-Path $folder 'dangling.yml'
        $null = New-Item -ItemType SymbolicLink -Path $dangling -Value (Join-Path $folder 'missing-target.yml')
        $directory = Join-Path $folder 'directory.yml'
        $null = New-Item -ItemType Directory -Path $directory
        foreach ($final in @($file, $dangling, $directory)) {
            $temp = Join-Path $folder ("candidate.{0}.tmp" -f [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($temp, 'candidate')
            $outcome = Publish-WorkloadSequenceFile -TempPath $temp -FinalPath $final
            Assert-False $outcome.Published "'$final' was replaced"
            Assert-StringEqual 'exists' $outcome.Reason
            Assert-True (Test-Path -LiteralPath $temp) 'the candidate was removed after a refused publish'
        }
        Assert-StringEqual 'original' ([IO.File]::ReadAllText($file))
        Assert-NotNull ([IO.FileInfo]::new($dangling).LinkTarget) 'the dangling link was replaced'
        Assert-False (Test-Path -LiteralPath (Join-Path $folder 'missing-target.yml')) 'the link target was created'
        Assert-True (Test-Path -LiteralPath $directory -PathType Container) 'the directory was replaced'
    }

    It 'refuses the save when the name appears between validation and publish' {
        $session = New-SequenceFileFixture
        $script:RaceTarget = Join-Path $session.SequencesDir 'workload.guest.ubuntu.server.24.race.yml'
        $script:RealChain = Get-Command Resolve-NamedSequenceChain -CommandType Function
        Mock Resolve-NamedSequenceChain -ModuleName Test.WorkloadSequenceFile {
            [IO.File]::WriteAllText($script:RaceTarget, 'other-writer')
            & $script:RealChain @PesterBoundParameters
        }
        $result = Invoke-FixtureSave -Session $session -Suffix 'race'
        Assert-StringEqual 'workload_name_exists' $result.error.code
        Assert-StringEqual 'other-writer' ([IO.File]::ReadAllText($script:RaceTarget))
        Assert-Equal 0 (Get-FixtureTempFile -Folder $session.SequencesDir).Count
    }

    It 'reports a publish as done when only the temporary name could not be removed' {
        $folder = Join-Path $TestDrive 'undeleted'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $temp = Join-Path $folder 'candidate.yml.1-00000000000000000000000000000000.tmp'
        [IO.File]::WriteAllText($temp, 'candidate bytes')
        $final = Join-Path $folder 'candidate.yml'
        Mock Remove-Item -ModuleName Test.WorkloadSequenceFile { throw [System.UnauthorizedAccessException]::new('denied') }
        $outcome = Publish-WorkloadSequenceFile -TempPath $temp -FinalPath $final
        Assert-True $outcome.Published 'the publish was not reported as done'
        Assert-StringEqual 'candidate bytes' ([IO.File]::ReadAllText($final))
        Assert-True (Test-Path -LiteralPath $temp) 'the temporary name was removed'
    }

    It 'writes nothing and leaves no temporary file when <Case>' -ForEach @(
        @{ Case = 'the candidate is invalid'; Code = 'workload_candidate_invalid' }
        @{ Case = 'a prerequisite is missing'; Code = 'workload_candidate_invalid' }
        @{ Case = 'the publish throws'; Code = '' }
        @{ Case = 'the text holds a secret'; Code = 'workload_secret_found' }
    ) {
        $session = New-SequenceFileFixture
        $journal = Get-DefaultFixtureJournal
        $prerequisites = @('start.guest.ubuntu.server.24')
        switch ($Case) {
            'the candidate is invalid' {
                $journal = @(New-JournalFixtureEntry -Seq 1 -Tool 'workload_action' -Authored ([ordered]@{ action = 'waitForText'; timeoutSeconds = 'ten'; description = 'Not an integer' }))
            }
            'a prerequisite is missing' { $prerequisites = @('start.guest.ubuntu.server.99') }
            'the publish throws' { Mock Publish-WorkloadSequenceFile -ModuleName Test.WorkloadSequenceFile { throw 'fixture publish failure' } }
            'the text holds a secret' {
                $journal = @(New-JournalFixtureEntry -Seq 1 -Tool 'workload_action' -Authored ([ordered]@{ action = 'sshExec'; command = 'echo fixture-registered-secret'; description = 'Leaks' }))
            }
        }
        if ($Code) {
            $result = Invoke-FixtureSave -Session $session -Entry $journal -Suffix 'nothing' -Prerequisite $prerequisites
            Assert-StringEqual $Code $result.error.code
        } else {
            Assert-Throw { $null = Invoke-FixtureSave -Session $session -Entry $journal -Suffix 'nothing' -Prerequisite $prerequisites } 'fixture publish failure'
        }
        Assert-False (Test-Path -LiteralPath (Join-Path $session.SequencesDir 'workload.guest.ubuntu.server.24.nothing.yml')) 'a file was written'
        Assert-Equal 0 (Get-FixtureTempFile -Folder $session.SequencesDir).Count
    }

    It 'removes temporary candidates older than one hour and keeps younger ones' {
        $session = New-SequenceFileFixture
        $old = Join-Path $session.SequencesDir ('workload.guest.ubuntu.server.24.old.yml.4242-{0}.tmp' -f ('a' * 32))
        $young = Join-Path $session.SequencesDir ('workload.guest.ubuntu.server.24.young.yml.4242-{0}.tmp' -f ('b' * 32))
        foreach ($path in @($old, $young)) { [IO.File]::WriteAllText($path, 'left behind') }
        [IO.File]::SetLastWriteTimeUtc($old, [DateTime]::UtcNow.AddHours(-2))
        [IO.File]::SetLastWriteTimeUtc($young, [DateTime]::UtcNow.AddMinutes(-10))
        $result = Invoke-FixtureSave -Session $session -Suffix 'sweep'
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        Assert-False (Test-Path -LiteralPath $old) 'a candidate older than one hour was kept'
        Assert-True (Test-Path -LiteralPath $young) 'a younger candidate was removed'
    }

    It 'the temporary name is not hidden and does not end in .yml' {
        $session = New-SequenceFileFixture
        $script:PublishedTemp = [Collections.Generic.List[string]]::new()
        $script:RealPublish = Get-Command Publish-WorkloadSequenceFile -Module Test.WorkloadSequenceFile
        Mock Publish-WorkloadSequenceFile -ModuleName Test.WorkloadSequenceFile { $script:PublishedTemp.Add($TempPath); & $script:RealPublish @PesterBoundParameters }
        $result = Invoke-FixtureSave -Session $session -Suffix 'temp-name'
        Assert-True ($result.ok -eq $true) "the save was refused with $($result.error.code)"
        Assert-Equal 1 $script:PublishedTemp.Count
        $leaf = Split-Path -Leaf $script:PublishedTemp[0]
        Assert-False $leaf.StartsWith('.') "the temporary name '$leaf' is hidden"
        Assert-False $leaf.EndsWith('.yml') "the temporary name '$leaf' ends in .yml"
        Assert-True ($leaf -cmatch '^workload\.guest\.ubuntu\.server\.24\.temp-name\.yml\.\d+-[0-9a-f]{32}\.tmp$') "the temporary name is '$leaf'"
    }
}
