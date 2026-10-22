<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42c231a1-4c53-4217-8d5b-b85c629fe1c7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic snapshot kubernetes pester
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
    Exercises per-report diagnostic snapshots using the standalone production functions.
.DESCRIPTION
    Known table shapes, transient failures and native stream
    outcomes are exercised without requiring Kubernetes or a host hypervisor.
#>

BeforeAll {
    $script:DiagnosticPath = Join-Path $PSScriptRoot '../../automation/Get-SystemDiagnostic.ps1'
    $script:DiagnosticAst = [Management.Automation.Language.Parser]::ParseFile($script:DiagnosticPath, [ref]$null, [ref]$null)
    $script:Pwsh = (Get-Process -Id $PID).Path
    foreach ($name in @('Invoke-Tool', 'Invoke-DiagnosticBoundedCommand', 'Test-ExecutableFile',
            'Get-DiagnosticKubeSnapshot', 'Get-DiagnosticHelmSnapshot', 'Invoke-WithDeadline')) {
        $definition = $script:DiagnosticAst.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function Format-YurunaOperatorMessage {
        param($Key, $Arguments, $FormatValues, $FormatBindings)
        $null = $Arguments, $FormatValues, $FormatBindings
        return $Key
    }
    function Add-Problem {
        param($Message, $Class)
        $script:Problems.Add(@{ Message = $Message; Class = $Class })
    }
    function kubectl {
        $script:KubeCalls.Add(@($args))
        $global:LASTEXITCODE = $script:KubeExit
        if ($null -ne $script:KubeResponses) {
            $key = $args -join ' '
            if ($key -like '*jsonpath=*') { $script:ImageQuery = $key; 'localhost:5000/website/web:1'; return }
            if (-not $script:KubeResponses.ContainsKey($key)) { throw "Unexpected quiet query: $key" }
            $script:KubeResponses[$key]
        } else { $script:KubeOutput }
    }
    function helm {
        $script:HelmCalls++
        $global:LASTEXITCODE = $script:HelmExit
        $script:HelmOutput
    }
    function Write-Sub { param($Title) $Title }
    function Test-CommandAvailable { param($Name) $null = $Name; return $true }
    function Get-FileTreeWithDeadline { param($Label, $ArgumentList, $ScriptBlock)
        $null = $ArgumentList, $ScriptBlock
        return @{ Items = @(if ($Label -eq 'resources.output.yml scan') { $script:OutputFile } else { $script:StateFile }) }
    }
    function Show-FileTreeWalkTimeout { param($Walk) $null = $Walk }
    function Get-LocalRegistryCatalog { return , @('website/web', 'unused/image') }
    $script:KubeBody = $script:DiagnosticAst.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DiagnosticSection' -and
            $node.CommandElements[1].Value -eq 'KUBERNETES' }, $true).CommandElements[2].ScriptBlock.GetScriptBlock()
    $script:GapBody = $script:DiagnosticAst.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DiagnosticSection' -and
            $node.CommandElements[1].Value -eq 'GAP HEURISTICS' }, $true).CommandElements[2].ScriptBlock.GetScriptBlock()
}

Describe 'Per-report diagnostic snapshots' {
BeforeEach {
    $script:DiagnosticKubeRows = @{}
    $script:DiagnosticHelmReleases = $null
    $script:Problems = [Collections.Generic.List[object]]::new()
    $script:KubeCalls = [Collections.Generic.List[object]]::new()
    $script:KubeExit = 0
    $script:KubeOutput = @()
    $script:KubeResponses = $null
    $script:HelmCalls = 0
    $script:HelmExit = 0
    $script:HelmOutput = '[]'
    $script:LinuxPriv = @()
}

Describe 'Kubernetes snapshots retain the production table shape' {
    It 'reuses <Resource> rows for both the initial classification and later gap checks' -ForEach @(
        @{ Resource = 'nodes'; Header = 'NAME STATUS ROLES AGE VERSION INTERNAL-IP'; Row = 'node-a NotReady control-plane 3m v1.37.1 10.0.0.2' }
        @{ Resource = 'pods'; Header = 'NAMESPACE NAME READY STATUS RESTARTS AGE IP NODE'; Row = 'website web-a 0/1 CrashLoopBackOff 7 3m 10.0.0.3 node-a' }
        @{ Resource = 'ns'; Header = 'NAME STATUS AGE'; Row = 'website Active 3m' }
        @{ Resource = 'deploy'; Header = 'NAMESPACE NAME READY UP-TO-DATE AVAILABLE AGE'; Row = 'website web 0/1 1 0 3m' }
    ) {
        $snapshot = @{ Success = $true; Lines = @($Header, $Row) }
        @(Get-DiagnosticKubeSnapshot -Resource $Resource -Snapshot $snapshot) | Should -Be @($Row)
        $script:KubeOutput = 'changed after collection'
        @(Get-DiagnosticKubeSnapshot -Resource $Resource) | Should -Be @($Row)
        $script:KubeCalls.Count | Should -Be 0
    }

    It 'retains zero, one and several rows as a normal pipeline collection' -ForEach @(0, 1, 3) {
        $count = $_
        $rows = @(for ($i = 0; $i -lt $count; $i++) { "ns$i Active 2m" })
        Get-DiagnosticKubeSnapshot -Resource ns -Snapshot @{ Success = $true; Lines = @('NAME STATUS AGE') + $rows } -PrimeOnly
        $names = @(Get-DiagnosticKubeSnapshot -Resource ns | ForEach-Object { ($_ -split '\s+')[0] })
        $names.Count | Should -Be $count
        if ($count -gt 0) { $names[0] | Should -Be 'ns0' }
        $script:KubeCalls.Count | Should -Be 0
    }

    It 'accepts a successful empty stdout table as an empty resource list' {
        @(Get-DiagnosticKubeSnapshot -Resource pods -Snapshot @{ Success = $true; Lines = @() }).Count | Should -Be 0
        @(Get-DiagnosticKubeSnapshot -Resource pods).Count | Should -Be 0
        $script:KubeCalls.Count | Should -Be 0
    }

    It 'does not prime an unrecognized header or failed table' -ForEach @(
        @{ Success = $true; Lines = @('different columns', 'bad row') }
        @{ Success = $false; Lines = @('NAME STATUS AGE', 'bad Active 2m') }
        @{ Success = $true; Lines = @('NAME STATUS AGE', 'truncated') }
    ) {
        $script:KubeOutput = 'live Active 3m'
        Get-DiagnosticKubeSnapshot -Resource ns -Snapshot $_ -PrimeOnly
        $script:KubeCalls.Count | Should -Be 0
        @(Get-DiagnosticKubeSnapshot -Resource ns) | Should -Be @('live Active 3m')
        $script:KubeCalls.Count | Should -Be 1
    }

    It 'retries a failed quiet query and only reuses its successful recovery' {
        $script:KubeExit = 1
        @(Get-DiagnosticKubeSnapshot -Resource pods).Count | Should -Be 0
        $script:KubeExit = 0
        $script:KubeOutput = 'website web-a 1/1 Running 0 3m'
        @(Get-DiagnosticKubeSnapshot -Resource pods) | Should -Be @($script:KubeOutput)
        @(Get-DiagnosticKubeSnapshot -Resource pods) | Should -Be @($script:KubeOutput)
        $script:KubeCalls.Count | Should -Be 2
        $script:KubeCalls[0] | Should -Be @('get', 'pods', '-A', '--no-headers', '--request-timeout=5s')
    }

    It 'resets dynamic data between report invocations' {
        $script:KubeOutput = 'node-a Ready control-plane 2m v1.37.1'
        @(Get-DiagnosticKubeSnapshot -Resource nodes)[0] | Should -Match 'Ready'
        $script:DiagnosticKubeRows = @{}
        $script:KubeOutput = 'node-a NotReady control-plane 2m v1.37.1'
        @(Get-DiagnosticKubeSnapshot -Resource nodes)[0] | Should -Match 'NotReady'
        $script:KubeCalls.Count | Should -Be 2
    }

    It 'does not reuse malformed quiet output even when its process exits successfully' {
        $script:KubeOutput = 'truncated'
        @(Get-DiagnosticKubeSnapshot -Resource nodes) | Should -Be @('truncated')
        $script:KubeOutput = 'node-a Ready control-plane 2m v1.37.1'
        @(Get-DiagnosticKubeSnapshot -Resource nodes) | Should -Be @($script:KubeOutput)
        $script:KubeCalls.Count | Should -Be 2
    }
}

Describe 'Helm snapshot validity and recovery' {
    It 'reuses valid arrays with zero, one or multiple releases' -ForEach @(0, 1, 3) {
        $count = $_
        $releases = @(for ($i = 0; $i -lt $count; $i++) { @{ name = "release$i"; namespace = 'website'; status = 'failed' } })
        $script:HelmOutput = ConvertTo-Json -InputObject $releases -Compress
        $initial = Get-DiagnosticHelmSnapshot
        $initial.Available | Should -BeTrue
        $initial.Releases.Count | Should -Be $count
        $script:HelmOutput = '[]'
        (Get-DiagnosticHelmSnapshot).Releases.Count | Should -Be $count
        $script:HelmCalls | Should -Be 1
    }

    It 'retries <Json> instead of caching an unusable JSON shape' -ForEach @(
        @{ Json = 'null' }, @{ Json = '{}' }, @{ Json = '"scalar"' }, @{ Json = '{broken' }, @{ Json = '' },
        @{ Json = '[null]' }, @{ Json = '[{}]' }, @{ Json = '[{"name":"web","namespace":"website","status":false}]' }
    ) {
        $script:HelmOutput = $Json
        (Get-DiagnosticHelmSnapshot).Available | Should -BeFalse
        $script:HelmOutput = '[]'
        (Get-DiagnosticHelmSnapshot).Available | Should -BeTrue
        $script:HelmCalls | Should -Be 2
    }

    It 'does not cache valid JSON from a failed process' {
        $script:HelmExit = 1
        (Get-DiagnosticHelmSnapshot).Available | Should -BeFalse
        $script:HelmExit = 0
        (Get-DiagnosticHelmSnapshot).Available | Should -BeTrue
        $script:HelmCalls | Should -Be 2
    }
}

Describe 'Native table capture preserves output and excludes incomplete evidence' {
    It 'captures only successful stdout rows while retaining both output streams in the report' {
        $snapshot = @{}
        $output = @(Invoke-Tool -Tool $script:Pwsh -ToolArgs @('-NoProfile', '-Command',
                '[Console]::Write("NAME STATUS AGE`r`nwebsite Active 3m`r`n"); [Console]::Error.WriteLine("warning")') -TimeoutSeconds 5 -Snapshot $snapshot)
        $output | Should -Be @('NAME STATUS AGE', 'website Active 3m', 'warning')
        $snapshot.Success | Should -BeTrue
        $snapshot.Lines | Should -Be @('NAME STATUS AGE', 'website Active 3m')
    }

    It 'does not reuse failed native output but preserves it as evidence' {
        $snapshot = @{}
        $output = @(Invoke-Tool -Tool $script:Pwsh -ToolArgs @('-NoProfile', '-Command',
                '[Console]::WriteLine("partial"); exit 3') -TimeoutSeconds 5 -Snapshot $snapshot)
        $output | Should -Be @('partial')
        $snapshot.Success | Should -BeFalse
        $snapshot.Lines.Count | Should -Be 0
    }

    It 'captures an unbounded successful table using the existing native pipeline' {
        $snapshot = @{}
        $output = @(Invoke-Tool -Tool $script:Pwsh -ToolArgs @('-NoProfile', '-Command',
                '[Console]::WriteLine("NAME STATUS AGE"); [Console]::WriteLine("website Active 3m")') -Snapshot $snapshot)
        $output | Should -Be @('NAME STATUS AGE', 'website Active 3m')
        $snapshot.Success | Should -BeTrue
        $snapshot.Lines | Should -Be $output
    }

    It 'does not prime the unbounded pipeline from merged stderr warnings' {
        $snapshot = @{}
        $output = @(Invoke-Tool -Tool $script:Pwsh -ToolArgs @('-NoProfile', '-Command',
                '[Console]::WriteLine("NAME STATUS AGE"); [Console]::Error.WriteLine("warning"); exit 0') -Snapshot $snapshot)
        $output | Should -Contain 'NAME STATUS AGE'
        $output | Should -Contain 'warning'
        $snapshot.Success | Should -BeFalse
        $snapshot.Lines.Count | Should -Be 0
    }

    It 'does not reuse timed out or incomplete native results' -ForEach @('TimedOut', 'DrainTimedOut', 'OutputTruncated', 'KillFailed') {
        $script:IncompleteFlag = $_
        Mock Invoke-DiagnosticBoundedCommand {
            $result = @{ Started = $true; ExitCode = 0; StdOut = 'partial'; StdErr = ''; TimedOut = $false;
                DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false }
            $result[$script:IncompleteFlag] = $true
            return $result
        }
        $snapshot = @{}
        $output = @(Invoke-Tool -Tool $script:Pwsh -TimeoutSeconds 5 -Snapshot $snapshot)
        $output[0] | Should -Be 'partial'
        $snapshot.Success | Should -BeFalse
        $snapshot.Lines.Count | Should -Be 0
    }

    It 'keeps merged worker output as evidence without reusing stderr as table rows' {
        Mock Get-Command { [pscustomobject]@{ CommandType = 'Function'; Source = '' } } -ParameterFilter { $Name -eq 'kubectl' }
        Mock Invoke-WithDeadline { @{ TimedOut = $false; Output = @('NAME STATUS AGE', 'website Active 3m', 'stderr warning', 0) } }
        $snapshot = @{}
        $output = @(Invoke-Tool -Tool kubectl -TimeoutSeconds 5 -Snapshot $snapshot)
        $output | Should -Be @('NAME STATUS AGE', 'website Active 3m', 'stderr warning')
        $snapshot.Success | Should -BeFalse
        $snapshot.Lines.Count | Should -Be 0
    }
}

Describe 'Production Kubernetes and gap sections consume the same snapshots' {
    It 'retains printed tables and unhealthy classifications without the nine duplicate reads' {
        $script:SkipKube = $false
        $script:SkipProjectGaps = $false
        $script:DiagnosticEvidenceRoot = $TestDrive
        $project = Join-Path $TestDrive project
        $null = New-Item -ItemType Directory -Path $project
        $outputPath = Join-Path $project resources.output.yml
        [IO.File]::WriteAllText($outputPath, "globalVariables:`n  namespace: missing`n")
        $script:OutputFile = Get-Item -LiteralPath $outputPath
        $script:StateFile = $script:OutputFile
        $script:Tables = @{
            nodes = @('NAME STATUS ROLES AGE VERSION INTERNAL-IP', 'node-a NotReady control-plane 3m v1.37.1 10.0.0.2', 'node-b Ready worker 3m v1.37.1 10.0.0.3')
            pods = @('NAMESPACE NAME READY STATUS RESTARTS AGE IP NODE', 'website broken 0/1 CrashLoopBackOff 1 3m 10.0.0.4 node-b', 'website restarted 1/1 Running 7 3m 10.0.0.5 node-b')
            ns = @('NAME STATUS AGE', 'default Active 3m', 'website Active 3m', 'orphan Active 3m')
            deploy = @('NAMESPACE NAME READY UP-TO-DATE AVAILABLE AGE', 'website web 0/1 1 0 3m')
        }
        $script:KubeResponses = @{
            'version --output=json --request-timeout=5s' = '{"clientVersion":{"gitVersion":"v1"},"serverVersion":{"gitVersion":"v1"}}'
            'get cm -A --no-headers --request-timeout=5s' = 'website config 1 3m'
            'get secret -A --no-headers --request-timeout=5s' = 'website secret 1 3m'
            'get events -A --field-selector type=Warning --sort-by .lastTimestamp --request-timeout=5s' = @('NAMESPACE LAST SEEN TYPE REASON OBJECT MESSAGE', 'website 1m Warning BackOff pod/broken failed')
            'get events -A --field-selector type=Warning --no-headers --request-timeout=5s' = 'website 1m Warning BackOff pod/broken failed'
        }
        $script:HelmOutput = '[{"name":"web","namespace":"website","status":"failed"}]'
        Mock Invoke-Tool {
            if ($Tool -eq 'kubectl' -and $ToolArgs[0] -eq 'get' -and $script:Tables.ContainsKey($ToolArgs[1])) {
                $lines = $script:Tables[$ToolArgs[1]]
                $lines
                if ($null -ne $Snapshot) { $Snapshot.Success = $true; $Snapshot.Lines = $lines }
            } else { 'other printed evidence' }
        }
        $printed = @(& $script:KubeBody; & $script:GapBody)
        foreach ($table in $script:Tables.Values) {
            foreach ($line in $table) { $printed | Should -Contain $line }
        }
        $script:Problems.Class | Should -Be @('KUBE.node-unhealthy', 'KUBE.pod-unhealthy', 'KUBE.pod-restarts',
            'KUBE.warning-events', 'HELM.release-unhealthy', 'KUBE.namespace-empty', 'GAP.declared-namespace-missing', 'GAP.registry-image-not-referenced')
        $script:KubeCalls.Count | Should -Be 6
        $script:HelmCalls | Should -Be 1
        $script:ImageQuery | Should -Match 'initContainers'
        $script:ImageQuery | Should -Match 'ephemeralContainers'
    }
}
}
