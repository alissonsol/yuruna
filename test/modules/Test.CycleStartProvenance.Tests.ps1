<#PSScriptInfo
.VERSION 2026.11.23
.GUID 422b8d9d-ee36-4c20-b920-5d584af0ebff
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test telemetry provenance ndjson pester
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
    Pester coverage for the commit provenance Start-LogFile stamps on the
    cycle-opening NDJSON event, and for that field's typing in
    Test.EventSchema.
.DESCRIPTION
    Throw-based assertions (Pester 5+). The record is
    proved end-to-end -- a temp TestRoot, a real cycle folder, the line
    Start-LogFile actually appended -- because the event is assembled inline at
    the emit site, so a test that stopped short of the file would not be
    testing what a consumer reads.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Log.psm1')         -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.Assert.psm1')      -Force -Global -DisableNameChecking

# The runner loads its transcript proxy before opening a cycle. A temporary
# TestRoot contains logs only, so it cannot supply the fallback module path.
$script:HadLogProxy = [bool](Get-Module Yuruna.Log)
if (-not $script:HadLogProxy) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Log.psm1') -Global -DisableNameChecking -ErrorAction Stop
}

# Fixtures live at FILE scope, not inside the Describe: a Describe body runs
# during discovery and everything it declares is discarded before any It runs,
# so a helper defined there is a CommandNotFoundException by the time an It
# calls it. The $global:__Yuruna* channels Start-LogFile publishes are saved and
# restored here through Save-YurunaTestGlobal and Restore-YurunaTestGlobal.
function New-CycleStartFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: temp dir + saves globals; no production state.')]
    [OutputType([hashtable])]
    param()
    $saved = Save-YurunaTestGlobal -Name '__YurunaCycleFolder', '__YurunaLogFile', '__YurunaCycleIdentity', '__YurunaCycleStartUtc'
    $root = New-YurunaTestTempDir -Prefix 'yrn-cyclestart'
    return @{ Root = $root; Saved = $saved }
}

function Restore-CycleStartFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test teardown: restores saved globals and removes the temp dir.')]
    param([Parameter(Mandatory)][hashtable]$Fixture)
    Restore-YurunaTestGlobal -Saved $Fixture.Saved
    Remove-YurunaTestTempDir $Fixture.Root
}

function Get-EmittedCycleStart {
    <#
    .SYNOPSIS
        Parse the first line of the cycle folder's event stream -- the
        cycle-opening record -- from a fixture root.
    .OUTPUTS
        [psobject] the parsed record.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory)][string]$Root)
    $nd = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'cycle.events.ndjson' | Select-Object -First 1
    if (-not $nd) { throw "Start-LogFile wrote no cycle.events.ndjson under $Root" }
    return @(Get-Content -LiteralPath $nd.FullName)[0] | ConvertFrom-Json
}

function ConvertTo-EventHashtable {
    <#
    .SYNOPSIS
        Re-hydrate an emitted NDJSON line into the hashtable shape the schema
        validator takes.
    .DESCRIPTION
        ConvertFrom-Json coerces an ISO-8601 string into [datetime], so a
        record read back through it no longer carries the wire types the schema
        describes. Restoring the string form is what makes the validation a
        statement about the emitted line rather than about the parser's type
        guesses.
    .OUTPUTS
        [hashtable] one key per property of the parsed record.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][psobject]$Record)
    $h = @{}
    foreach ($p in $Record.PSObject.Properties) {
        # Assigned through a variable, never straight off an if-expression: an
        # if-statement's output pipeline unrolls a single-element array to a
        # bare object, which would turn a one-commit gitCommits into the very
        # type error this record is being validated for.
        $value = $p.Value
        if ($value -is [datetime]) {
            $value = ([datetime]$value).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        $h[$p.Name] = $value
    }
    return $h
}

}

AfterAll {
    if (-not $script:HadLogProxy) {
        Remove-Module -Name Yuruna.Log -Force -ErrorAction SilentlyContinue
    }
}

Describe 'cycle_start commit provenance' {

    It 'carries the cycle commits in the status document gitCommits shape, framework first' {
        $fx = New-CycleStartFixture
        try {
            $commits = @(
                [ordered]@{ sha = 'aa11bb2'; repoUrl = 'https://example.invalid/framework' }
                [ordered]@{ sha = 'cc33dd4'; repoUrl = 'https://example.invalid/project' }
            )
            $null = Start-LogFile -TestRoot $fx.Root -CycleStartUtc '2026-01-02T03:04:05Z' -Hostname 'fixture-host' -CycleNumber 7 -GitCommits $commits -Confirm:$false
            $rec = Get-EmittedCycleStart -Root $fx.Root
            Assert-Equal -Expected 'cycle_start' -Actual $rec.event -Because 'event name'
            Assert-Equal -Expected 2 -Actual @($rec.gitCommits).Count -Because 'framework + project entries'
            Assert-Equal -Expected 'aa11bb2' -Actual @($rec.gitCommits)[0].sha -Because 'the framework entry leads'
            Assert-Equal -Expected 'https://example.invalid/project' -Actual @($rec.gitCommits)[1].repoUrl -Because 'project repoUrl'
            # Flat [{...}] on the wire, never [[{...}]] -- the array-double-wrap
            # regression class, which every commit reader rejects outright.
            Assert-True (@($rec.gitCommits)[0] -isnot [array]) 'gitCommits must be a FLAT array of commit objects'
        } finally { Restore-CycleStartFixture -Fixture $fx }
    }

    It 'omits gitCommits when the driver has no commit context' {
        $fx = New-CycleStartFixture
        try {
            $null = Start-LogFile -TestRoot $fx.Root -CycleStartUtc '2026-01-02T03:04:05Z' -Hostname 'fixture-host' -CycleNumber 7 -Confirm:$false
            $rec = Get-EmittedCycleStart -Root $fx.Root
            # Absent, not a one-element array holding $null: "no commits were
            # recorded" and "a commit whose sha could not be read" must not
            # reach a consumer as the same value.
            Assert-True ($null -eq $rec.gitCommits) 'gitCommits must be absent when no commits were supplied'
        } finally { Restore-CycleStartFixture -Fixture $fx }
    }

    It 'emits a cycle_start record that passes the cycle-event schema' {
        $fx = New-CycleStartFixture
        try {
            $commits = @([ordered]@{ sha = 'aa11bb2'; repoUrl = 'https://example.invalid/framework' })
            $null = Start-LogFile -TestRoot $fx.Root -CycleStartUtc '2026-01-02T03:04:05Z' -Hostname 'fixture-host' -CycleNumber 7 -GitCommits $commits -Confirm:$false
            $rec = ConvertTo-EventHashtable -Record (Get-EmittedCycleStart -Root $fx.Root)
            $violations = @(Test-CycleEventSchema -Record $rec)
            Assert-Equal -Expected 0 -Actual $violations.Count -Because "schema violations: $($violations -join '; ')"
        } finally { Restore-CycleStartFixture -Fixture $fx }
    }

    It 'types gitCommits in the cycle-event schema descriptor' {
        $descriptor = Get-CycleEventSchemaDescriptor
        Assert-Equal -Expected 'array' -Actual $descriptor.TypedField['gitCommits'] -Because 'the field must be typed by the validator, not merely tolerated as an unknown key'
    }

    It 'flags a gitCommits value that is not an array' {
        $rec = @{ timestamp = '2026-01-02T03:04:05Z'; event = 'cycle_start'; gitCommits = 'aa11bb2' }
        $violations = @(Test-CycleEventSchema -Record $rec)
        Assert-True (($violations -join '; ') -match 'gitCommits') 'a scalar gitCommits must be reported'
    }
}

# An orchestration owns its cycle through Register-StandaloneCycle, which built
# plain {sha, repoUrl} entries of its own, so the source provenance the runner
# attached to each commit never reached status.json or the cycle_start event of
# a host whose plan is an orchestration.
Describe 'Owner cycle commit provenance' {
    BeforeAll {
        # Loaded only for this Describe: a status document left loaded would be
        # rewritten by every later Start-LogFile through Set-CycleFolderUrl.
        $script:OwnerCycleModules = @('Test.Orchestrator', 'Test.Status', 'Test.HostGit' | Where-Object { -not (Get-Module -Name $_) })
        Import-Module (Join-Path $here 'Test.HostGit.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.Status.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.Orchestrator.psm1') -Force -Global -DisableNameChecking -WarningAction SilentlyContinue
        function Invoke-OwnerCycleFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes status and cycle files under a temp dir only.')]
            [OutputType([hashtable])]
            param([object[]]$GitCommits, [switch]$FrameworkAtCheckout)
            $fx = New-CycleStartFixture
            $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
            try {
                $env:YURUNA_RUNTIME_DIR = $fx.Root
                $statusPath = Join-Path $fx.Root 'status.json'
                # A real checkout, so the entries read without a handed list exist.
                $repoRoot = New-YurunaTestGitRepository -Path (Join-Path $fx.Root 'framework') -CommitMessage 'Fixture framework'
                $registerArgs = @{
                    StatusFilePath = $statusPath; HostType = 'host.ubuntu.kvm'
                    Config = @{ repositories = @{ frameworkUrl = 'https://example.invalid/framework' } }
                    RepoRoot = $repoRoot; TestRoot = $fx.Root; GuestList = @('suite'); StepNames = @('Run')
                }
                if ($FrameworkAtCheckout) { $GitCommits[0]['sha'] = [string](git -C $repoRoot rev-parse HEAD) }
                if ($GitCommits) { $registerArgs.GitCommits = $GitCommits }
                $null = Register-StandaloneCycle @registerArgs
                return @{
                    Status = @((Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json).gitCommits)
                    Event  = @((Get-EmittedCycleStart -Root $fx.Root).gitCommits)
                }
            } finally {
                Restore-YurunaTestEnvironment -Saved $savedRuntime
                Restore-CycleStartFixture -Fixture $fx
            }
        }
    }
    AfterAll {
        foreach ($name in $script:OwnerCycleModules) { Remove-Module -Name $name -Force -ErrorAction SilentlyContinue }
    }

    It 'writes the source provenance of a handed commit list to status.json and the cycle_start event' {
        $commits = @(
            [ordered]@{ sha = 'aa11bb2'; repoUrl = 'https://example.invalid/framework'; source = 'mirror'; verification = 'mirror-stale'; fallbackReason = 'origin-transport-failed' }
            [ordered]@{ sha = 'cc33dd4'; repoUrl = 'https://example.invalid/project'; source = 'origin'; verification = 'origin-current' }
        )
        $actual = Invoke-OwnerCycleFixture -GitCommits $commits
        foreach ($surface in @('Status', 'Event')) {
            Assert-Equal -Expected 2 -Actual $actual[$surface].Count -Because "$surface carries framework and project"
            Assert-Equal -Expected 'aa11bb2' -Actual $actual[$surface][0].sha -Because "$surface keeps the framework first"
            Assert-Equal -Expected 'mirror' -Actual $actual[$surface][0].source -Because "$surface keeps the framework source"
            Assert-Equal -Expected 'mirror-stale' -Actual $actual[$surface][0].verification -Because "$surface keeps the verification"
            Assert-Equal -Expected 'origin-transport-failed' -Actual $actual[$surface][0].fallbackReason -Because "$surface keeps the fallback reason"
            Assert-Equal -Expected 'origin' -Actual $actual[$surface][1].source -Because "$surface keeps the project source"
        }
    }

    It 'keeps the web origin it resolved for a handed entry of the same revision' {
        $commits = @(
            [ordered]@{ sha = ''; repoUrl = 'git@example.invalid:owner/framework.git'; source = 'mirror'; verification = 'mirror-confirmed' }
        )
        $actual = Invoke-OwnerCycleFixture -GitCommits $commits -FrameworkAtCheckout
        foreach ($surface in @('Status', 'Event')) {
            Assert-Equal -Expected 'https://example.invalid/framework' -Actual $actual[$surface][0].repoUrl -Because "$surface publishes the resolved web origin"
            Assert-Equal -Expected 'mirror-confirmed' -Actual $actual[$surface][0].verification -Because "$surface keeps the handed verification"
        }
    }

    It 'records plain entries without source provenance when no commit list is handed over' {
        $actual = Invoke-OwnerCycleFixture
        foreach ($surface in @('Status', 'Event')) {
            Assert-Equal -Expected 1 -Actual $actual[$surface].Count -Because "$surface carries the framework checkout revision"
            foreach ($entry in $actual[$surface]) {
                Assert-Equal -Expected 'sha,repoUrl' -Actual (@($entry.PSObject.Properties.Name) -join ',') -Because "$surface keeps the plain entry shape"
            }
        }
    }
}

Describe 'cycle_start PowerShell provenance' {

    It 'carries the runner''s PowerShell version as $PSVersionTable prints it' {
        $fx = New-CycleStartFixture
        try {
            $null = Start-LogFile -TestRoot $fx.Root -CycleStartUtc '2026-01-02T03:04:05Z' -Hostname 'fixture-host' -CycleNumber 7 -Confirm:$false
            $rec = Get-EmittedCycleStart -Root $fx.Root
            Assert-StringEqual -Expected ([string]$PSVersionTable.PSVersion) -Actual ([string]$rec.runnerPowerShellVersion) 'the release that ran the cycle'
            Assert-True ($rec.runnerPowerShellVersion -is [string]) 'the version is text, as a reader compares it'
        } finally { Restore-CycleStartFixture -Fixture $fx }
    }

    It 'types runnerPowerShellVersion as a string in the cycle-event schema' {
        $descriptor = Get-CycleEventSchemaDescriptor
        Assert-Equal -Expected 'string' -Actual $descriptor.TypedField['runnerPowerShellVersion'] -Because 'the field must be typed by the validator, not merely tolerated as an unknown key'
        $violations = @(Test-CycleEventSchema -Record @{ timestamp = '2026-01-02T03:04:05Z'; event = 'cycle_start'; runnerPowerShellVersion = 7 })
        Assert-True (($violations -join '; ') -match 'runnerPowerShellVersion') 'a version that is not text must be reported'
    }
}
