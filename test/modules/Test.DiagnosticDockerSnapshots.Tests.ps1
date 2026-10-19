<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42f7097c-d2c6-4913-bdac-ef76cfaa6580
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic docker snapshot pester
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
    Exercises successful Docker snapshot reuse in the standalone diagnostic.
.DESCRIPTION
    Production functions and the complete Docker section are loaded from its
    AST. Native capture failures, compatibility workers, table alignment and
    report-local freshness are covered without a Docker daemon dependency.
#>

BeforeAll {
    $script:DiagnosticPath = Join-Path $PSScriptRoot '../../automation/Get-SystemDiagnostic.ps1'
    $script:Ast = [Management.Automation.Language.Parser]::ParseFile($script:DiagnosticPath, [ref]$null, [ref]$null)
    $script:Pwsh = (Get-Process -Id $PID).Path
    foreach ($name in @('Get-DiagnosticDockerInfoProbe', 'Get-DiagnosticDockerContainerSnapshot',
            'Invoke-DiagnosticBoundedCommand', 'Invoke-WithDeadline', 'Invoke-Tool', 'Test-ExecutableFile')) {
        $definition = $script:Ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        if ($name -eq 'Invoke-DiagnosticBoundedCommand') { $script:NativeBody = $definition.Body.GetScriptBlock() }
        if ($name -eq 'Get-DiagnosticDockerInfoProbe') {
            $script:WindowsInfoProbe = [scriptblock]::Create($definition.Body.GetScriptBlock().ToString().Replace('$IsWindows', '$true'))
        }
    }
    $script:DockerBody = $script:Ast.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DiagnosticSection' -and
            $node.CommandElements[1].Value -eq 'DOCKER' }, $true).CommandElements[2].ScriptBlock.GetScriptBlock()
    function Format-YurunaOperatorMessage {
        param($Key, $FormatValues, $FormatBindings)
        $null = $FormatBindings
        return "$Key $($FormatValues -join ',')".TrimEnd()
    }
    function Add-Problem { param($Message, $Class) $script:Problems.Add(@{ Message = $Message; Class = $Class }) }
    function Write-Sub { param($Title) return $Title }
    function Test-CommandAvailable { param($Name) $null = $Name; return $script:CommandAvailable }
    function Get-LocalRegistryCatalog { return , @('example/web') }
    function Get-DockerFixtureInfoJson {
        param([string]$Version = '29.0.0', [string[]]$Warnings = @())
        return ([ordered]@{
                ServerVersion = $Version; Containers = 5; ContainersRunning = 2; ContainersPaused = 0
                ContainersStopped = 3; Images = 7; Driver = 'overlay2'; CgroupDriver = 'systemd'
                KernelVersion = '6.17.0'; OperatingSystem = 'Ubuntu'; Warnings = $Warnings
            } | ConvertTo-Json -Compress)
    }
    function Get-DockerFixtureTable {
        param([object[]]$Rows = @())
        '{0,-30} {1,-65} {2,-45} {3}' -f 'NAMES', 'IMAGE', 'STATUS', 'PORTS'
        foreach ($row in $Rows) { '{0,-30} {1,-65} {2,-45} {3}' -f $row.Name, $row.Image, $row.Status, $row.Ports }
    }
}

Describe 'Standalone Docker report snapshots' {
    BeforeEach {
        $script:Problems = [Collections.Generic.List[object]]::new()
        $script:DeadlineCalls = [Collections.Generic.List[string]]::new()
        $script:ToolCalls = [Collections.Generic.List[object]]::new()
        $script:CommandAvailable = $true
        $script:SkipDocker = $false
        $script:InfoJson = Get-DockerFixtureInfoJson
        $script:Native = @{
            Started = $true; ExitCode = 0; StdOut = $script:InfoJson; StdErr = ''
            TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false; StartError = ''
        }
        $script:Resolved = [pscustomobject]@{ CommandType = 'Application'; Source = $script:Pwsh }
        $script:ContainerTable = @(Get-DockerFixtureTable)
        $script:ContainerTableSuccess = $true
        $script:QuietRows = @()
        $script:QuietTimedOut = $false
        $script:InfoTimedOut = $false
        Mock Get-Command { return $script:Resolved } -ParameterFilter { $Name -eq 'docker' }
        Mock Test-ExecutableFile { return $true }
        Mock Invoke-DiagnosticBoundedCommand { return $script:Native }
        Mock Invoke-WithDeadline {
            $body = $ScriptBlock.ToString()
            $script:DeadlineCalls.Add($body)
            if ($body -match 'docker images') {
                return @{ TimedOut = $false; Output = @('example/web|1|abc123|1MB|2 hours ago', 0) }
            }
            if ($body -match 'docker ps') { return @{ TimedOut = $script:QuietTimedOut; Output = $script:QuietRows } }
            if ($body -match 'json \.') { return @{ TimedOut = $script:InfoTimedOut; Output = $script:InfoJson } }
            return @{ TimedOut = $false; Output = @(0) }
        }
    }

    Describe 'Info liveness and data come from one complete native response' {
        It 'retains all info fields and uses the native argument, timeout and capture bounds' {
            $snapshot = @{}
            $script:Native.StdErr = 'a client warning on stderr'
            $probe = Get-DiagnosticDockerInfoProbe -Snapshot $snapshot
            $snapshot.Success | Should -BeTrue
            $snapshot.Info.ServerVersion | Should -Be '29.0.0'
            $snapshot.Info.Containers | Should -Be 5
            $snapshot.Info.Images | Should -Be 7
            $snapshot.Info.CgroupDriver | Should -Be 'systemd'
            $probe.Output | Should -Be @(0)
            $probe.Evidence.Count | Should -Be 0
            Should -Invoke Invoke-WithDeadline -Times 0
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 1 -ParameterFilter {
                $FilePath -eq $script:Pwsh -and $TimeoutSeconds -eq 5 -and $MaxCapturedChars -eq 16777216 -and
                ($ArgumentList -join '|') -eq 'info|--format|{{json .}}'
            }
        }

        It 'retains zero counters and Unicode warning text' {
            $warning = "warning `u{e9} `u{6f22} `u{1f642}"
            $data = Get-DockerFixtureInfoJson -Warnings @($warning) | ConvertFrom-Json
            $data.Containers = 0; $data.ContainersRunning = 0; $data.ContainersPaused = 0; $data.ContainersStopped = 0; $data.Images = 0
            $script:Native.StdOut = $data | ConvertTo-Json -Compress
            $snapshot = @{}
            Get-DiagnosticDockerInfoProbe -Snapshot $snapshot | Out-Null
            $snapshot.Success | Should -BeTrue
            $snapshot.Info.Containers | Should -Be 0
            $snapshot.Info.Warnings | Should -Be @($warning)
        }

        It 'does not treat malformed or incomplete JSON as a reusable info object: <Kind>' -ForEach @(
            @{ Kind = 'empty'; Json = '' }
            @{ Kind = 'invalid'; Json = '{' }
            @{ Kind = 'null'; Json = 'null' }
            @{ Kind = 'empty array'; Json = '[]' }
            @{ Kind = 'array containing info'; Json = 'array' }
            @{ Kind = 'number'; Json = '42' }
            @{ Kind = 'string'; Json = '"text"' }
            @{ Kind = 'boolean'; Json = 'true' }
            @{ Kind = 'empty object'; Json = '{}' }
            @{ Kind = 'missing fields'; Json = '{"ServerVersion":"29.0.0"}' }
        ) {
            $script:Native.StdOut = if ($Json -eq 'array') { "[$script:InfoJson]" } else { $Json }
            $snapshot = @{ Success = $true; Info = 'stale data' }
            $probe = Get-DiagnosticDockerInfoProbe -Snapshot $snapshot
            $snapshot.Success | Should -BeFalse
            $snapshot.Info | Should -BeNullOrEmpty
            $probe.Output | Should -Be @(0)
        }

        It 'does not cache a capture with <Flag>, retaining its evidence' -ForEach @(
            @{ Flag = 'TimedOut'; Value = $true }
            @{ Flag = 'DrainTimedOut'; Value = $true }
            @{ Flag = 'OutputTruncated'; Value = $true }
            @{ Flag = 'KillFailed'; Value = $true }
            @{ Flag = 'Started'; Value = $false }
            @{ Flag = 'ExitCode'; Value = 17 }
        ) {
            $script:Native[$Flag] = $Value
            $script:Native.StdErr = 'daemon error detail'
            $script:Native.StartError = 'executable start detail'
            $snapshot = @{}
            $probe = Get-DiagnosticDockerInfoProbe -Snapshot $snapshot
            $snapshot.Success | Should -BeFalse
            $snapshot.Info | Should -BeNullOrEmpty
            ($probe.Evidence -join "`n") | Should -Match 'daemon error detail'
            ($probe.Evidence -join "`n") | Should -Match 'ServerVersion'
            $probe.TimedOut | Should -Be ($Flag -eq 'TimedOut')
            $probe.Output | Should -Be @($(if ($Flag -eq 'ExitCode') { 17 } else { -1 }))
            if ($Flag -eq 'Started') { $probe.Evidence | Should -Contain 'executable start detail' }
            if ($Flag -in @('DrainTimedOut', 'OutputTruncated', 'KillFailed')) {
                ($probe.Evidence -join "`n") | Should -Match "$Flag=True"
            }
        }

        It 'retries after a failed call and resets a previously successful snapshot on the next report' {
            $snapshot = @{}
            $script:Native.ExitCode = 1
            Get-DiagnosticDockerInfoProbe -Snapshot $snapshot | Out-Null
            $snapshot.Success | Should -BeFalse
            $script:Native.ExitCode = 0
            $script:Native.StdOut = Get-DockerFixtureInfoJson -Version '30.1.0'
            Get-DiagnosticDockerInfoProbe -Snapshot $snapshot | Out-Null
            $snapshot.Info.ServerVersion | Should -Be '30.1.0'
            $script:Native.StdOut = 'invalid next report'
            Get-DiagnosticDockerInfoProbe -Snapshot $snapshot | Out-Null
            $snapshot.Success | Should -BeFalse
            $snapshot.Info | Should -BeNullOrEmpty
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 3
        }

        It 'preserves the compatibility worker for <_> commands' -ForEach @('Function', 'Alias', 'ExternalScript') {
            $script:Resolved = [pscustomobject]@{ CommandType = $_; Source = '' }
            $snapshot = @{}
            (Get-DiagnosticDockerInfoProbe -Snapshot $snapshot).Output | Should -Be @(0)
            $snapshot.Success | Should -BeFalse
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 0
            Should -Invoke Invoke-WithDeadline -Times 1 -ParameterFilter { $TimeoutSeconds -eq 5 }
        }

        It 'keeps Windows <_> shims on the interpreter path' -ForEach @('.cmd', '.bat') {
            $script:Resolved = [pscustomobject]@{ CommandType = 'Application'; Source = "C:\tools\docker$_" }
            $snapshot = @{}
            & $script:WindowsInfoProbe -Snapshot $snapshot | Out-Null
            $snapshot.Success | Should -BeFalse
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 0
            Should -Invoke Invoke-WithDeadline -Times 1
        }

        It 'handles an absent command under strict mode without accessing its Source' {
            $script:Resolved = $null
            $snapshot = @{}
            & {
                Set-StrictMode -Version Latest
                Get-DiagnosticDockerInfoProbe -Snapshot $snapshot
            } | Out-Null
            $snapshot.Success | Should -BeFalse
            Should -Invoke Invoke-WithDeadline -Times 1
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 0
        }

        It 'retains an unexpected native capture failure as daemon evidence without aborting the report' {
            Mock Invoke-DiagnosticBoundedCommand { throw 'native reader failure detail' }
            $snapshot = @{}
            $probe = Get-DiagnosticDockerInfoProbe -Snapshot $snapshot
            $snapshot.Success | Should -BeFalse
            $probe.Output | Should -Be @(-1)
            $probe.Evidence | Should -Contain 'native reader failure detail'
        }

        It 'does not launch a target that no longer passes executable-file validation' {
            Mock Test-ExecutableFile { return $false }
            Get-DiagnosticDockerInfoProbe -Snapshot @{} | Out-Null
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 0
            Should -Invoke Invoke-WithDeadline -Times 1
        }
    }

    Describe 'Container health comes from the unchanged printed table' {
        It 'accepts <Kind> as a successful empty container list' -ForEach @(
            @{ Kind = 'empty stdout'; Lines = @() }
            @{ Kind = 'header only'; Lines = @('NAMES  IMAGE  STATUS  PORTS') }
        ) {
            $result = Get-DiagnosticDockerContainerSnapshot -Snapshot @{ Success = $true; Lines = $Lines }
            $result.Success | Should -BeTrue
            $result.Rows.Count | Should -Be 0
        }

        It 'retains zero, one and several rows as individual name/status records' -ForEach @(0, 1, 3) {
            $rows = @(for ($i = 0; $i -lt $_; $i++) {
                    @{ Name = "web$i"; Image = 'localhost:5000/long/image/name:tag'; Status = 'Up 2 hours (unhealthy)'; Ports = '0.0.0.0:8080->80/tcp' }
                })
            $table = @(Get-DockerFixtureTable -Rows $rows)
            $result = Get-DiagnosticDockerContainerSnapshot -Snapshot @{ Success = $true; Lines = $table }
            $result.Success | Should -BeTrue
            $result.Rows.Count | Should -Be $_
            if ($_ -gt 0) { $result.Rows[0] | Should -Be 'web0|Up 2 hours (unhealthy)' }
        }

        It 'separates long status text from ports and keeps rows without a ports field' {
            $table = @(Get-DockerFixtureTable -Rows @(
                    @{ Name = 'long-container-name-123456789'; Image = 'localhost:5000/long/repository/image:tag'; Status = 'Restarting (128) 25 seconds ago'; Ports = 'unhealthy-test-port' }
                    @{ Name = 'web'; Image = 'image:tag'; Status = 'Up 2 hours (healthy)'; Ports = '' }
                ))
            $table[2] = $table[2].TrimEnd()
            $result = Get-DiagnosticDockerContainerSnapshot -Snapshot @{ Success = $true; Lines = $table }
            $result.Success | Should -BeTrue
            $result.Rows | Should -Be @('long-container-name-123456789|Restarting (128) 25 seconds ago', 'web|Up 2 hours (healthy)')
            $result.Rows | Should -Not -Match 'test-port'
        }

        It 'rejects a failed printed capture even when its surviving table is valid' {
            $result = Get-DiagnosticDockerContainerSnapshot -Snapshot @{ Success = $false; Lines = @(Get-DockerFixtureTable) }
            $result.Success | Should -BeFalse
        }

        It 'rejects an unknown or partial table: <Kind>' -ForEach @(
            @{ Kind = 'unknown header'; Lines = @('NAME IMAGE STATE PORT') }
            @{ Kind = 'wrong-case header'; Lines = @('names  image  status  ports', 'web    image  Dead') }
            @{ Kind = 'reordered header'; Lines = @('NAMES STATUS IMAGE PORTS') }
            @{ Kind = 'truncated row'; Lines = @('NAMES  IMAGE  STATUS  PORTS', 'web') }
            @{ Kind = 'misaligned row'; Lines = @('NAMES  IMAGE  STATUS  PORTS', 'web          Dead') }
            @{ Kind = 'empty image'; Lines = @('NAMES  IMAGE  STATUS  PORTS', 'web           Dead') }
            @{ Kind = 'empty name'; Lines = @('NAMES  IMAGE  STATUS  PORTS', '       image Dead') }
            @{ Kind = 'empty status'; Lines = @('NAMES  IMAGE  STATUS  PORTS', 'web    image        ') }
        ) {
            $result = Get-DiagnosticDockerContainerSnapshot -Snapshot @{ Success = $true; Lines = $Lines }
            $result.Success | Should -BeFalse
            $result.Rows.Count | Should -Be 0
        }
    }

    Describe 'The complete Docker section preserves evidence and health classifications' {
        BeforeEach {
            Mock Invoke-Tool {
                $script:ToolCalls.Add(@($ToolArgs))
                if ($ToolArgs[0] -eq 'ps') {
                    $Snapshot.Success = $script:ContainerTableSuccess
                    $Snapshot.Lines = $script:ContainerTable
                    $script:ContainerTable
                } else { "tool evidence: $($ToolArgs[0])" }
            }
        }

        It 'prints the original table and info while classifying all unhealthy states without duplicate queries' {
            $script:Native.StdOut = Get-DockerFixtureInfoJson -Warnings @('warning detail')
            $script:ContainerTable = @(Get-DockerFixtureTable -Rows @(
                    @{ Name = 'restart'; Image = 'img:1'; Status = 'Restarting (1) 2 seconds ago'; Ports = '' }
                    @{ Name = 'unhealthy'; Image = 'img:2'; Status = 'Up 2 hours (unhealthy)'; Ports = '80/tcp' }
                    @{ Name = 'dead'; Image = 'img:3'; Status = 'Dead'; Ports = '' }
                    @{ Name = 'healthy'; Image = 'img:4'; Status = 'Up 2 hours'; Ports = '' }
                ))
            $output = @(& $script:DockerBody)
            foreach ($line in $script:ContainerTable) { $output | Should -Contain $line }
            $output | Should -Contain '  - warning detail'
            @($script:Problems | Where-Object Class -eq 'DOCKER.warning').Count | Should -Be 1
            @($script:Problems | Where-Object Class -eq 'DOCKER.container-unhealthy').Count | Should -Be 3
            @($script:DeadlineCalls | Where-Object { $_ -match 'docker info|docker ps' }).Count | Should -Be 0
            $script:DeadlineCalls.Count | Should -Be 1
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 1
        }

        It 'retries malformed successful info before displaying and classifying its fresh warnings' {
            $script:Native.StdOut = '{"ServerVersion":"partial"}'
            $script:InfoJson = Get-DockerFixtureInfoJson -Version 'fresh retry' -Warnings @('retry warning')
            $output = @(& $script:DockerBody)
            ($output -join "`n") | Should -Match 'fresh retry'
            @($script:Problems | Where-Object Class -eq 'DOCKER.warning').Count | Should -Be 1
            @($script:DeadlineCalls | Where-Object { $_ -match 'docker info' }).Count | Should -Be 1
        }

        It 'retains the existing info timeout class when malformed data requires a fresh query' {
            $script:Native.StdOut = 'invalid'
            $script:InfoTimedOut = $true
            & $script:DockerBody | Out-Null
            @($script:Problems | Where-Object Class -eq 'DOCKER.probe-timeout').Count | Should -Be 1
        }

        It 'retries a failed table with the original quiet query and uses its fresh status' {
            $script:ContainerTableSuccess = $false
            $script:QuietRows = @('fresh|Dead')
            & $script:DockerBody | Out-Null
            @($script:Problems | Where-Object Class -eq 'DOCKER.container-unhealthy').Count | Should -Be 1
            $script:Problems[0].Message | Should -Be "DOCKER: container 'fresh' status: Dead"
            @($script:DeadlineCalls | Where-Object { $_ -match 'docker ps' }).Count | Should -Be 1
        }

        It 'retains the existing quiet-container timeout marker and class' {
            $script:ContainerTable = @('bad format')
            $script:QuietTimedOut = $true
            $output = @(& $script:DockerBody)
            ($output -join "`n") | Should -Match 'automation.operator_5ba0dbd55dfbc5f1'
            @($script:Problems | Where-Object Class -eq 'DOCKER.probe-timeout').Count | Should -Be 1
        }

        It 'stops the Docker section on a <Flag> daemon probe and retains its evidence' -ForEach @(
            @{ Flag = 'TimedOut'; Value = $true; Class = 'DOCKER.probe-timeout' }
            @{ Flag = 'ExitCode'; Value = 9; Class = 'DOCKER.daemon-unavailable' }
            @{ Flag = 'DrainTimedOut'; Value = $true; Class = 'DOCKER.daemon-unavailable' }
        ) {
            $script:Native[$Flag] = $Value
            $script:Native.StdErr = 'daemon failure detail'
            $output = @(& $script:DockerBody)
            ($output -join "`n") | Should -Match 'daemon failure detail'
            $script:Problems.Count | Should -Be 1
            $script:Problems[0].Class | Should -Be $Class
            $script:ToolCalls.Count | Should -Be 0
            $script:DeadlineCalls.Count | Should -Be 0
        }

        It 'performs no native or worker probes when <Kind>' -ForEach @(
            @{ Kind = 'Docker is skipped'; Skip = $true; Available = $true }
            @{ Kind = 'Docker is not installed'; Skip = $false; Available = $false }
        ) {
            $script:SkipDocker = $Skip; $script:CommandAvailable = $Available
            & $script:DockerBody | Out-Null
            $script:Problems.Count | Should -Be 0
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 0
            Should -Invoke Invoke-WithDeadline -Times 0
        }

        It 'keeps the entire compatibility path valid under strict mode without stdout provenance' {
            $script:Resolved = [pscustomobject]@{ CommandType = 'Function'; Source = '' }
            $script:ContainerTableSuccess = $false
            & {
                Set-StrictMode -Version Latest
                & $script:DockerBody
            } | Out-Null
            $script:DeadlineCalls.Count | Should -Be 4
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 0
        }

        It 'collects fresh daemon and container data on each complete report invocation' {
            & $script:DockerBody | Out-Null
            $script:Native.StdOut = Get-DockerFixtureInfoJson -Version 'next report' -Warnings @('new report warning')
            $script:ContainerTable = @(Get-DockerFixtureTable -Rows @(@{ Name = 'later'; Image = 'img'; Status = 'Dead'; Ports = '' }))
            $output = @(& $script:DockerBody)
            ($output -join "`n") | Should -Match 'next report'
            @($script:Problems | Where-Object Class -eq 'DOCKER.warning').Count | Should -Be 1
            @($script:Problems | Where-Object Class -eq 'DOCKER.container-unhealthy').Count | Should -Be 1
            Should -Invoke Invoke-DiagnosticBoundedCommand -Times 2
        }
    }

    Describe 'Actual native capture reaches the production snapshot boundary' {
        It 'captures literal arguments, Unicode JSON and stderr separately without a daemon' -Skip:$IsWindows {
            $warning = "warning `u{e9} `u{6f22} `u{1f642}"
            $json = Get-DockerFixtureInfoJson -Warnings @($warning)
            $fixture = Join-Path $TestDrive "docker fixture `u{e9}"
            $content = @"
#!/bin/sh
[ "`$1" = 'info' ] || exit 91
[ "`$2" = '--format' ] || exit 92
[ "`$3" = '{{json .}}' ] || exit 93
printf '%s\n' '$json'
printf '%s\n' 'stderr detail' >&2
"@
            [IO.File]::WriteAllText($fixture, $content, [Text.UTF8Encoding]::new($false))
            [IO.File]::SetUnixFileMode($fixture, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
            $script:Resolved = [pscustomobject]@{ CommandType = 'Application'; Source = $fixture }
            Mock Invoke-DiagnosticBoundedCommand {
                & $script:NativeBody -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds -MaxCapturedChars $MaxCapturedChars
            }
            $snapshot = @{}
            $probe = Get-DiagnosticDockerInfoProbe -Snapshot $snapshot
            $snapshot.Success | Should -BeTrue
            $snapshot.Info.Warnings | Should -Be @($warning)
            $probe.Output | Should -Be @(0)
            $probe.Evidence.Count | Should -Be 0
        }

        It 'keeps a real nonzero native response as daemon failure evidence' -Skip:$IsWindows {
            $fixture = Join-Path $TestDrive 'docker failure'
            [IO.File]::WriteAllText($fixture, "#!/bin/sh`nprintf '%s\n' 'actual daemon error' >&2`nexit 23`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::SetUnixFileMode($fixture, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
            $script:Resolved = [pscustomobject]@{ CommandType = 'Application'; Source = $fixture }
            Mock Invoke-DiagnosticBoundedCommand {
                & $script:NativeBody -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds -MaxCapturedChars $MaxCapturedChars
            }
            $snapshot = @{}
            $probe = Get-DiagnosticDockerInfoProbe -Snapshot $snapshot
            $snapshot.Success | Should -BeFalse
            $probe.Output | Should -Be @(23)
            ($probe.Evidence -join "`n") | Should -Match 'actual daemon error'
        }
    }
}
