<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42386fcb-9b22-4111-8798-b33f5405c9ec
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload helm kubectl diagnostic log pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Holds the per-tool logs the workload publisher writes -- helm.stderr.log for
    a chart, <tool>.stderr.log for a kubectl / helm / shell deployment -- and
    their .rc sidecars to their exact bytes.
.DESCRIPTION
    A project reaches these files through Set-Workload, and the system
    diagnostic reads them after a failure: every *.stderr.log is printed, and
    the .rc beside it is looked up by name. The content is therefore a contract
    with whoever reads the post-mortem: one section per tool call, a
    "== <command> (exit=N) ==" header, then the call's output one line per
    object, and an .rc holding the last exit code with no line terminator.

    Each test runs the real deployment function against stand-ins for helm and
    kubectl -- global functions, which PowerShell resolves ahead of an
    executable of the same name, so an installed helm is never started and a
    host without one runs the same tests. The stand-ins take their output and
    exit code from a plan the test supplies and record the arguments they were
    called with.

    The last Describe holds the mechanism: a chart section reaches the log
    through one append, header and output together, and the publisher itself
    opens the log for none of them.

    The retry helper stamps each of its headers with the time, so Get-Date is
    mocked inside the retry module, and Start-Sleep so that no test waits out a
    backoff. Everything is written under TestDrive.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Workload.psm1') -Force -DisableNameChecking

    $script:Stamp = '2026-09-27T12:34:56Z'
    $script:EnvironmentName = @('contextName', 'workFolder', 'YURUNA_RETRY_MAX_ATTEMPTS', 'YURUNA_RETRY_DELAY_SECONDS')

    function ConvertTo-LogHex {
        <#
        .SYNOPSIS
            The bytes a log holding these lines must have, as hexadecimal text:
            UTF-8 with no byte order mark, every line followed by the platform
            line terminator.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([string[]]$Line)
        $text = [System.Text.StringBuilder]::new()
        foreach ($entry in $Line) { $null = $text.Append($entry).Append([Environment]::NewLine) }
        return [System.BitConverter]::ToString([System.Text.UTF8Encoding]::new($false).GetBytes($text.ToString()))
    }

    function Confirm-LogContent {
        <#
        .SYNOPSIS
            Fails unless the file holds exactly the given lines, byte for byte.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, Position = 0)][string]$Path,
            [Parameter(Position = 1)][string[]]$Line,
            [Parameter(Position = 2)][string]$Because = ''
        )
        $expected = ConvertTo-LogHex -Line $Line
        $actual = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($Path))
        Assert-StringEqual $expected $actual ("$Because`nThe log holds:`n" + [System.IO.File]::ReadAllText($Path))
    }

    function Confirm-ExitCodeFile {
        <#
        .SYNOPSIS
            Fails unless the sidecar holds the exit code and nothing else: no
            line terminator, no byte order mark.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, Position = 0)][string]$Path,
            [Parameter(Mandatory, Position = 1)][int]$ExitCode
        )
        $expected = [System.BitConverter]::ToString([System.Text.Encoding]::ASCII.GetBytes([string]$ExitCode))
        $actual = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($Path))
        Assert-StringEqual $expected $actual "$Path must hold the bare exit code"
    }

    function New-ToolPlan {
        <#
        .SYNOPSIS
            A plan for a stand-in tool: what each verb prints and exits with,
            and the list its calls are recorded in.
        .PARAMETER Step
            Verb -> @{ Exit = <int>; Emit = <items>; Before = <scriptblock> }.
            An item is a string for a line on the output stream, or
            @{ Error = '<text>' } for a line on the error stream, or $null for a
            null object on the output stream. Before is optional and runs in
            the folder the tool was started in, ahead of the output.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture description.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][hashtable]$Step)
        return @{ Step = $Step; Call = [System.Collections.Generic.List[string]]::new() }
    }

    function Set-ToolStandIn {
        <#
        .SYNOPSIS
            Defines a global function that stands in for a native tool and
            follows the given plan.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Defines a test double that the suite removes again.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][hashtable]$Plan
        )
        $toolName = $Name
        $toolPlan = $Plan
        Set-Item -Path "Function:global:$Name" -Value {
            $verb = [string]$args[0]
            $toolPlan.Call.Add((@($args | ForEach-Object { [string]$_ }) -join ' '))
            if (-not $toolPlan.Step.ContainsKey($verb)) { throw "the $toolName stand-in has no step for '$verb'" }
            $step = $toolPlan.Step[$verb]
            if ($step.ContainsKey('Before')) { & $step.Before }
            foreach ($item in $step.Emit) {
                if ($item -is [hashtable]) { Write-Error -Message $item.Error -ErrorAction Continue }
                else { $item }
            }
            $global:LASTEXITCODE = [int]$step.Exit
        }.GetNewClosure()
    }

    function New-ChartFixture {
        <#
        .SYNOPSIS
            A project folder holding one chart named sample; returns the folder
            the chart deployment will keep its log in.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates an isolated fixture beneath TestDrive.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Root)
        $chart = Join-Path $Root 'workloads/sample'
        $null = New-Item -ItemType Directory -Force -Path $chart
        [System.IO.File]::WriteAllText((Join-Path $chart 'Chart.yaml'), "apiVersion: v2`nname: sample`nversion: 1.0.0`n")
        return (Join-Path $Root '.yuruna/lab/workloads/fixture-context/fixture')
    }

    function Invoke-ChartFixture {
        <#
        .SYNOPSIS
            Runs the chart deployment of the fixture project and returns what
            it returned: nothing on success, a failure manifest otherwise.
        .PARAMETER Preference
            An error preference to set in the publisher's own scope first, the
            way a caller of the publisher would have it set.
        #>
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Root, [string]$Preference = '')
        InModuleScope Yuruna.Workload -Parameters @{ Root = $Root; Preference = $Preference } {
            if ($Preference) { $ErrorActionPreference = $Preference }
            Invoke-WorkloadChartDeployment -project_root $Root -config_subfolder 'lab' -contextName 'fixture-context' `
                -deployment @{ chart = 'sample'; variables = @{ installName = 'fixture' } } `
                -deploymentVars ([ordered]@{ replicas = '2' }) -workloadsFile 'workloads.yml' `
                -sw ([System.Diagnostics.Stopwatch]::StartNew())
        } 3>$null
    }

    function Invoke-ToolFixture {
        <#
        .SYNOPSIS
            Runs one kubectl deployment of the fixture project and returns what
            it returned: nothing on success, a failure manifest otherwise.
        #>
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Arguments)
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $Root '.yuruna/lab/workloads/fixture-context')
        InModuleScope Yuruna.Workload -Parameters @{ Root = $Root; Arguments = $Arguments } {
            $deployment = @{ kubectl = $Arguments }
            Invoke-WorkloadToolDeployment -kind (Resolve-YurunaDeploymentKind -Deployment $deployment) -project_root $Root `
                -config_subfolder 'lab' -contextName 'fixture-context' -deployment $deployment `
                -deploymentVars ([ordered]@{}) -sw ([System.Diagnostics.Stopwatch]::StartNew())
        }
    }
}

Describe 'the workload publisher keeps its tool logs byte for byte' {
    BeforeEach {
        $script:OriginalLocation = (Get-Location).Path
        $script:OriginalExit = $global:LASTEXITCODE
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name $script:EnvironmentName
        Remove-Item -LiteralPath 'Env:YURUNA_RETRY_MAX_ATTEMPTS', 'Env:YURUNA_RETRY_DELAY_SECONDS' -ErrorAction SilentlyContinue
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
        Mock -ModuleName 'Yuruna.Retry' Get-Date { [datetime]::new(2026, 9, 27, 12, 34, 56, [DateTimeKind]::Utc) }
    }

    AfterEach {
        Remove-Item -Path Function:/helm, Function:/kubectl -ErrorAction SilentlyContinue
        Set-Location -LiteralPath $script:OriginalLocation
        $global:LASTEXITCODE = $script:OriginalExit
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
    }

    Context 'a chart deployment (helm.stderr.log and helm.rc)' {
        It 'logs lint and the install of a release that is not there yet' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint    = @{ Exit = 0; Emit = @('==> Linting .', '[INFO] Chart.yaml: icon is recommended', '', '1 chart(s) linted, 0 chart(s) failed') }
                status  = @{ Exit = 1; Emit = @(@{ Error = 'Error: release: not found' }) }
                upgrade = @{ Exit = 0; Emit = @('Release "fixture" does not exist. Installing it now.', 'NAME: fixture', 'STATUS: deployed') }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $failure = Invoke-ChartFixture -Root $script:Root
            Assert-Null $failure 'a clean install returns nothing'
            Assert-StringEqual 'lint .|status fixture|upgrade --install --atomic fixture . --debug' ($plan.Call -join '|')
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=0) =='
                '==> Linting .', '[INFO] Chart.yaml: icon is recommended', '', '1 chart(s) linted, 0 chart(s) failed'
                '== helm upgrade --install --atomic fixture --debug (exit=0) =='
                'Release "fixture" does not exist. Installing it now.', 'NAME: fixture', 'STATUS: deployed')
            Confirm-ExitCodeFile (Join-Path $work 'helm.rc') 0
            Assert-StringEqual $script:OriginalLocation (Get-Location).Path
        }

        It 'stops at a failed lint with only the lint section and its exit code' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint = @{ Exit = 1; Emit = @('==> Linting .', @{ Error = '[ERROR] templates/: parse error' }, @{ Error = 'Error: 1 chart(s) linted, 1 chart(s) failed' }) }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $failure = Invoke-ChartFixture -Root $script:Root
            Assert-False $failure.success
            Assert-Equal 1 $failure.exitCode
            Assert-StringEqual 'lint .' ($plan.Call -join '|')
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=1) =='
                '==> Linting .', '[ERROR] templates/: parse error', 'Error: 1 chart(s) linted, 1 chart(s) failed')
            Confirm-ExitCodeFile (Join-Path $work 'helm.rc') 1
        }

        It 'writes a header alone for a call that printed nothing' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint    = @{ Exit = 0; Emit = @() }
                status  = @{ Exit = 1; Emit = @() }
                upgrade = @{ Exit = 0; Emit = @() }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $null = Invoke-ChartFixture -Root $script:Root
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=0) =='
                '== helm upgrade --install --atomic fixture --debug (exit=0) ==')
            Confirm-ExitCodeFile (Join-Path $work 'helm.rc') 0
        }

        It 'logs the status and the rollback of a release that was left pending' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint     = @{ Exit = 0; Emit = @('1 chart(s) linted, 0 chart(s) failed') }
                status   = @{ Exit = 0; Emit = @('NAME: fixture', 'STATUS: pending-upgrade', 'REVISION: 3') }
                rollback = @{ Exit = 0; Emit = @('Rollback was a success! Happy Helming!') }
                upgrade  = @{ Exit = 0; Emit = @('STATUS: deployed') }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $failure = Invoke-ChartFixture -Root $script:Root
            Assert-Null $failure
            Assert-StringEqual 'lint .|status fixture|rollback fixture 0|upgrade --install --atomic fixture . --debug' ($plan.Call -join '|')
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=0) ==', '1 chart(s) linted, 0 chart(s) failed'
                '== pre-flight helm status (state=pending-upgrade; recovering) ==', 'NAME: fixture', 'STATUS: pending-upgrade', 'REVISION: 3'
                '== helm rollback fixture 0 (exit=0) ==', 'Rollback was a success! Happy Helming!'
                '== helm upgrade --install --atomic fixture --debug (exit=0) ==', 'STATUS: deployed')
            Confirm-ExitCodeFile (Join-Path $work 'helm.rc') 0
        }

        It 'logs the uninstall that follows a rollback with nothing to roll back to' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint      = @{ Exit = 0; Emit = @('1 chart(s) linted, 0 chart(s) failed') }
                status    = @{ Exit = 0; Emit = @('NAME: fixture', 'STATUS: pending-install') }
                rollback  = @{ Exit = 1; Emit = @(@{ Error = 'Error: release has no 0 version' }) }
                uninstall = @{ Exit = 0; Emit = @('release "fixture" uninstalled') }
                upgrade   = @{ Exit = 0; Emit = @('STATUS: deployed') }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $failure = Invoke-ChartFixture -Root $script:Root
            Assert-Null $failure
            Assert-StringEqual 'lint .|status fixture|rollback fixture 0|uninstall fixture --no-hooks|upgrade --install --atomic fixture . --debug' ($plan.Call -join '|')
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=0) ==', '1 chart(s) linted, 0 chart(s) failed'
                '== pre-flight helm status (state=pending-install; recovering) ==', 'NAME: fixture', 'STATUS: pending-install'
                '== helm rollback fixture 0 (exit=1) ==', 'Error: release has no 0 version'
                '== helm uninstall fixture --no-hooks (exit=0) ==', 'release "fixture" uninstalled'
                '== helm upgrade --install --atomic fixture --debug (exit=0) ==', 'STATUS: deployed')
            Confirm-ExitCodeFile (Join-Path $work 'helm.rc') 0
        }

        It 'logs a failed install and reports it with the exit code the sidecar holds' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint    = @{ Exit = 0; Emit = @() }
                status  = @{ Exit = 1; Emit = @() }
                upgrade = @{ Exit = 1; Emit = @('history.go:56: [debug] getting history for release fixture', @{ Error = 'Error: UPGRADE FAILED: timed out waiting for the condition' }) }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $failure = Invoke-ChartFixture -Root $script:Root
            Assert-False $failure.success
            Assert-Equal 1 $failure.exitCode
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=0) =='
                '== helm upgrade --install --atomic fixture --debug (exit=1) =='
                'history.go:56: [debug] getting history for release fixture', 'Error: UPGRADE FAILED: timed out waiting for the condition')
            Confirm-ExitCodeFile (Join-Path $work 'helm.rc') 1
        }

        It 'keeps text outside ASCII, trailing spaces and a line break inside one object as they were printed' {
            $work = New-ChartFixture -Root $script:Root
            $accented = "caf$([char]0xE9) $([char]0x4E2D)$([char]0x6587)"
            $plan = New-ToolPlan -Step @{
                lint    = @{ Exit = 0; Emit = @($accented, 'trailing spaces   ', "one object`ntwo lines") }
                status  = @{ Exit = 1; Emit = @() }
                upgrade = @{ Exit = 0; Emit = @() }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $null = Invoke-ChartFixture -Root $script:Root
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=0) ==', $accented, 'trailing spaces   ', "one object`ntwo lines"
                '== helm upgrade --install --atomic fixture --debug (exit=0) ==')
        }

        It 'writes one empty line for a call whose whole output is a null object' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint    = @{ Exit = 0; Emit = @($null) }
                status  = @{ Exit = 1; Emit = @() }
                upgrade = @{ Exit = 0; Emit = @('a', $null, 'b') }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $null = Invoke-ChartFixture -Root $script:Root
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=0) ==', ''
                '== helm upgrade --install --atomic fixture --debug (exit=0) ==', 'a', '', 'b')
        }

        It 'starts each chart run from an empty log and sidecar' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint    = @{ Exit = 0; Emit = @('first run') }
                status  = @{ Exit = 1; Emit = @() }
                upgrade = @{ Exit = 0; Emit = @() }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $null = Invoke-ChartFixture -Root $script:Root
            $plan.Step.lint.Emit = @('second run')
            $null = Invoke-ChartFixture -Root $script:Root
            Confirm-LogContent (Join-Path $work 'helm.stderr.log') @(
                '== helm lint (exit=0) ==', 'second run'
                '== helm upgrade --install --atomic fixture --debug (exit=0) ==')
        }
    }

    Context 'a chart log that cannot be written' {
        BeforeEach {
            # The stand-in turns the log path into a folder while lint runs,
            # after the publisher cleared the old log and before its first
            # append: the content provider refuses to write to a folder on
            # every platform, and nothing else in the work folder is disturbed.
            $script:BlockLog = {
                $null = New-Item -ItemType Directory -Path 'helm.stderr.log'
                $null = New-Item -ItemType File -Path 'helm.stderr.log/keep'
            }
        }

        It 'does not stop the deployment while the publisher''s error preference is Continue' {
            $work = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint    = @{ Exit = 0; Emit = @('1 chart(s) linted, 0 chart(s) failed'); Before = $script:BlockLog }
                status  = @{ Exit = 1; Emit = @() }
                upgrade = @{ Exit = 0; Emit = @('STATUS: deployed') }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $failure = Invoke-ChartFixture -Root $script:Root -Preference 'Continue' 2>$null
            Assert-Null $failure 'a log that cannot be written is not a failed deployment'
            Assert-StringEqual 'lint .|status fixture|upgrade --install --atomic fixture . --debug' ($plan.Call -join '|')
            Confirm-ExitCodeFile (Join-Path $work 'helm.rc') 0
            Assert-True (Test-Path -LiteralPath (Join-Path $work 'helm.stderr.log') -PathType Container)
        }

        It 'stops the deployment at the first append while the publisher''s error preference is Stop' {
            $null = New-ChartFixture -Root $script:Root
            $plan = New-ToolPlan -Step @{
                lint    = @{ Exit = 0; Emit = @('1 chart(s) linted, 0 chart(s) failed'); Before = $script:BlockLog }
                status  = @{ Exit = 1; Emit = @() }
                upgrade = @{ Exit = 0; Emit = @('STATUS: deployed') }
            }
            Set-ToolStandIn -Name helm -Plan $plan
            $errorId = ''
            try { $null = Invoke-ChartFixture -Root $script:Root -Preference 'Stop' } catch { $errorId = [string]$_.FullyQualifiedErrorId }
            Assert-Match 'AddContentCommand$' $errorId 'the deployment must be stopped by the append itself'
            Assert-StringEqual 'lint .' ($plan.Call -join '|') 'no later helm call may run once the append stopped the deployment'
            Assert-StringEqual $script:OriginalLocation (Get-Location).Path
        }
    }

    Context 'a kubectl deployment (kubectl.stderr.log and kubectl.rc)' {
        It 'logs the attempt under the retry header and leaves the bare exit code beside it' {
            $work = Join-Path $script:Root '.yuruna/lab/workloads/fixture-context'
            $plan = New-ToolPlan -Step @{ apply = @{ Exit = 0; Emit = @('deployment.apps/sample created', 'service/sample created') } }
            Set-ToolStandIn -Name kubectl -Plan $plan
            $failure = Invoke-ToolFixture -Root $script:Root -Arguments 'apply -f manifest.yaml'
            Assert-Null $failure
            Assert-StringEqual 'apply -f manifest.yaml' ($plan.Call -join '|')
            Confirm-LogContent (Join-Path $work 'kubectl.stderr.log') @(
                "== $script:Stamp kubectl apply -f manifest.yaml attempt 1/5 (exit=0) =="
                'deployment.apps/sample created', 'service/sample created')
            Confirm-ExitCodeFile (Join-Path $work 'kubectl.rc') 0
            Assert-StringEqual $script:OriginalLocation (Get-Location).Path
        }

        It 'logs one section per attempt while a transient failure is retried' {
            $work = Join-Path $script:Root '.yuruna/lab/workloads/fixture-context'
            $plan = New-ToolPlan -Step @{ apply = @{ Exit = 1; Emit = @(@{ Error = 'Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout' }) } }
            Set-ToolStandIn -Name kubectl -Plan $plan
            $failure = Invoke-ToolFixture -Root $script:Root -Arguments 'apply -f manifest.yaml'
            Assert-False $failure.success
            Assert-Equal 5 $plan.Call.Count
            $expected = foreach ($attempt in 1..5) {
                "== $script:Stamp kubectl apply -f manifest.yaml attempt $attempt/5 (exit=1) =="
                'Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout'
            }
            Confirm-LogContent (Join-Path $work 'kubectl.stderr.log') @($expected)
            Confirm-ExitCodeFile (Join-Path $work 'kubectl.rc') 1
        }

        It 'appends a second deployment of the same tool to the same log' {
            $work = Join-Path $script:Root '.yuruna/lab/workloads/fixture-context'
            $plan = New-ToolPlan -Step @{
                apply  = @{ Exit = 0; Emit = @('applied') }
                delete = @{ Exit = 3; Emit = @(@{ Error = 'Error from server (NotFound): pods "gone" not found' }) }
            }
            Set-ToolStandIn -Name kubectl -Plan $plan
            $null = Invoke-ToolFixture -Root $script:Root -Arguments 'apply -f manifest.yaml'
            $failure = Invoke-ToolFixture -Root $script:Root -Arguments 'delete pod gone'
            Assert-False $failure.success
            Assert-Equal 3 $failure.exitCode
            Confirm-LogContent (Join-Path $work 'kubectl.stderr.log') @(
                "== $script:Stamp kubectl apply -f manifest.yaml attempt 1/5 (exit=0) ==", 'applied'
                "== $script:Stamp kubectl delete pod gone attempt 1/5 (exit=3) ==", 'Error from server (NotFound): pods "gone" not found')
            Confirm-ExitCodeFile (Join-Path $work 'kubectl.rc') 3
        }
    }
}

Describe 'the workload publisher appends once per chart section' {
    BeforeEach {
        $script:OriginalLocation = (Get-Location).Path
        $script:OriginalExit = $global:LASTEXITCODE
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name $script:EnvironmentName
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName 'Yuruna.Workload' Add-Content { }
        Mock -ModuleName 'Yuruna.Retry' Add-Content { }
    }

    AfterEach {
        Remove-Item -Path Function:/helm -ErrorAction SilentlyContinue
        Set-Location -LiteralPath $script:OriginalLocation
        $global:LASTEXITCODE = $script:OriginalExit
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
    }

    It 'writes the five sections of a recovered install in five appends, header and output together' {
        $null = New-ChartFixture -Root $script:Root
        $plan = New-ToolPlan -Step @{
            lint      = @{ Exit = 0; Emit = @(1..40 | ForEach-Object { "lint line $_" }) }
            status    = @{ Exit = 0; Emit = @('NAME: fixture', 'STATUS: pending-install') }
            rollback  = @{ Exit = 1; Emit = @(@{ Error = 'Error: release has no 0 version' }) }
            uninstall = @{ Exit = 0; Emit = @('release "fixture" uninstalled') }
            upgrade   = @{ Exit = 0; Emit = @(1..300 | ForEach-Object { "debug line $_" }) }
        }
        Set-ToolStandIn -Name helm -Plan $plan
        $null = Invoke-ChartFixture -Root $script:Root
        Should -Invoke Add-Content -ModuleName 'Yuruna.Workload' -Times 0 -Exactly
        Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 5 -Exactly
        Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 1 -Exactly -ParameterFilter {
            @($Value).Count -eq 41 -and @($Value)[0] -ceq '== helm lint (exit=0) =='
        }
        Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 1 -Exactly -ParameterFilter {
            @($Value).Count -eq 301 -and @($Value)[0] -ceq '== helm upgrade --install --atomic fixture --debug (exit=0) =='
        }
    }

    It 'writes a section that has no output in one append as well' {
        $null = New-ChartFixture -Root $script:Root
        $plan = New-ToolPlan -Step @{
            lint    = @{ Exit = 0; Emit = @() }
            status  = @{ Exit = 1; Emit = @() }
            upgrade = @{ Exit = 0; Emit = @() }
        }
        Set-ToolStandIn -Name helm -Plan $plan
        $null = Invoke-ChartFixture -Root $script:Root
        Should -Invoke Add-Content -ModuleName 'Yuruna.Workload' -Times 0 -Exactly
        Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 2 -Exactly
    }
}
