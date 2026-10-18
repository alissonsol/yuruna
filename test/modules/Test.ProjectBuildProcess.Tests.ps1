<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42a42fc4-3899-4caf-9b13-53b48db992a8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeDiscovery {
    $projectRoot = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'yuruna-project'
    $script:ProjectAvailable = Test-Path -LiteralPath (Join-Path $projectRoot 'tools/Example.Build.psm1')
}

Describe 'Certificate Secret failures protect submitted values' -Skip:(-not $script:ProjectAvailable) {
    BeforeAll {
        $projectRoot = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'yuruna-project'
        $script:CertificateModule = Import-Module (Join-Path $projectRoot 'tools/Example.Build.psm1') -Force -PassThru
        & $script:CertificateModule {
            $script:FixturePassword = 'private-fixture-password-42'
            $script:FixturePfx = [Text.Encoding]::UTF8.GetBytes('private-fixture-pfx-bytes-42')
            function script:Get-ExampleRandomPassword { return $script:FixturePassword }
            function script:Get-ExampleSelfSignedCertificate {
                $certificate = [pscustomobject]@{}
                $certificate | Add-Member -MemberType ScriptMethod -Name Export -Value { return $script:FixturePfx }
                $certificate | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
                return $certificate
            }
            function script:kubectl {
                $script:FixtureCalls.Add(($args -join ' '))
                $received = @($input) -join "`n"
                $global:LASTEXITCODE = 0
                $detail = 'fixture denial: ' + $script:FixturePassword + ' ' +
                    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:FixturePassword)) + ' ' +
                    [Convert]::ToBase64String($script:FixturePfx)
                if ($args[0] -eq 'create') {
                    $script:FixtureManifest = $received
                    if ($script:FixtureMode -eq 'createThrow') { throw "$detail $received" }
                    if ($script:FixtureMode -eq 'createExit') { $global:LASTEXITCODE = 19; return "$detail $received" }
                    return $received
                }
                if ($script:FixtureMode -eq 'deleteExit') { $global:LASTEXITCODE = 17; return $detail }
                return 'fixture deleted'
            }
        }
    }
    AfterAll { Remove-Module -ModuleInfo $script:CertificateModule -Force }

    It '<Mode> preserves status and useful errors without echoing Secret values' -ForEach @(
        @{ Mode = 'deleteExit'; Expected = 1; Calls = 1 }
        @{ Mode = 'createExit'; Expected = 1; Calls = 2 }
        @{ Mode = 'createThrow'; Expected = 1; Calls = 2 }
        @{ Mode = 'success'; Expected = 0; Calls = 2 }
    ) {
        $result = & $script:CertificateModule {
            param($Mode)
            $script:FixtureMode = $Mode
            $script:FixtureCalls = [Collections.Generic.List[string]]::new()
            $script:FixtureManifest = ''
            $records = @(Invoke-ExampleCertificateSecret -Namespace fixture-ns -SecretName fixture-cert -SelfSigned *>&1)
            [pscustomobject]@{
                Codes = @($records | Where-Object { $_ -is [int] })
                Text = ($records | Where-Object { $_ -isnot [int] } | ForEach-Object { [string]$_ }) -join "`n"
                Calls = @($script:FixtureCalls)
                Manifest = $script:FixtureManifest
                Sensitive = @($script:FixturePassword,
                    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:FixturePassword)),
                    [Convert]::ToBase64String($script:FixturePfx))
            }
        } $Mode
        $result.Codes.Count | Should -Be 1
        $result.Codes[0] | Should -Be $Expected
        $result.Calls.Count | Should -Be $Calls
        foreach ($value in $result.Sensitive) {
            $result.Text.Contains($value) | Should -BeFalse
            ($result.Calls -join ' ').Contains($value) | Should -BeFalse
        }
        if ($Expected -ne 0) {
            $result.Text | Should -Match 'fixture denial'
            $result.Text | Should -Match '<redacted>'
        }
        if ($Calls -eq 2) {
            $manifest = $result.Manifest | ConvertFrom-Json
            $manifest.data.password | Should -BeExactly $result.Sensitive[1]
            $manifest.data.'aspnetapp.pfx' | Should -BeExactly $result.Sensitive[2]
        }
    }
}

Describe 'Windows developer Docker launcher status and working directory' -Skip:(-not $script:ProjectAvailable -or -not $IsWindows) {
    BeforeAll {
        $projectRoot = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'yuruna-project'
        $script:DeveloperLauncher = Join-Path $projectRoot 'example/website/components/frontend/website/docker-run-dev.cmd'
    }

    It 'returns <Expected> after build <BuildExit> and run <RunExit> from another directory' -ForEach @(
        @{ BuildExit = 0; RunExit = 0; Expected = 0; Verbs = 'build,run' }
        @{ BuildExit = 7; RunExit = 0; Expected = 7; Verbs = 'build' }
        @{ BuildExit = 0; RunExit = 9; Expected = 9; Verbs = 'build,run' }
    ) {
        $stub = Join-Path $TestDrive 'docker.cmd'
        $log = Join-Path $TestDrive 'docker.calls'
        $passwordVariable = 'ASPNETCORE_Kestrel__Certificates__Default__Password'
        $names = @('PATH', 'DOCKER_TEST_LOG', 'DOCKER_TEST_BUILD_EXIT', 'DOCKER_TEST_RUN_EXIT', $passwordVariable)
        $ambient = @{}
        foreach ($name in $names) { $ambient[$name] = [Environment]::GetEnvironmentVariable($name) }
        [IO.File]::WriteAllText($stub, (@(
            '@echo off',
            'echo %1^|%CD%>>"%DOCKER_TEST_LOG%"',
            'if "%1"=="build" exit /b %DOCKER_TEST_BUILD_EXIT%',
            'exit /b %DOCKER_TEST_RUN_EXIT%'
        ) -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
        $location = Get-Location
        try {
            [Environment]::SetEnvironmentVariable('PATH', "$TestDrive$([IO.Path]::PathSeparator)$($ambient['PATH'])")
            [Environment]::SetEnvironmentVariable('DOCKER_TEST_LOG', $log)
            [Environment]::SetEnvironmentVariable('DOCKER_TEST_BUILD_EXIT', [string]$BuildExit)
            [Environment]::SetEnvironmentVariable('DOCKER_TEST_RUN_EXIT', [string]$RunExit)
            [Environment]::SetEnvironmentVariable($passwordVariable, 'launcher-fixture-password')
            Set-Location -LiteralPath $TestDrive
            $output = & $env:ComSpec /d /c $script:DeveloperLauncher 2>&1 | Out-String
            $LASTEXITCODE | Should -Be $Expected
            (Get-Location).Path | Should -Be $TestDrive
            $calls = @(Get-Content -LiteralPath $log)
            (($calls | ForEach-Object { ($_ -split '\|', 2)[0] }) -join ',') | Should -Be $Verbs
            foreach ($call in $calls) {
                ($call -split '\|', 2)[1] | Should -Be (Split-Path -Parent $script:DeveloperLauncher)
            }
            $output | Should -Not -Match 'launcher-fixture-password'
            [Environment]::GetEnvironmentVariable($passwordVariable) | Should -Be 'launcher-fixture-password'
        } finally {
            Set-Location -LiteralPath $location.Path
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $ambient[$name]) { [NullString]::Value } else { $ambient[$name] }))
            }
        }
    }
}

Describe 'Website deployment budgets agree across console and SSH' -Skip:(-not $script:ProjectAvailable) {
    BeforeAll {
        $script:BudgetProjectRoot = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'yuruna-project'
        Import-Module (Join-Path $PSScriptRoot '../../automation/Import.Yaml.psm1') -Force
    }

    It '<ConsolePath> gives the identical script its cold and warm SSH budget' -ForEach @(
        @{ Release = '24'; ConsolePath = 'example/website/test/workload.guest.ubuntu.server.24.k8s.website.yml' }
        @{ Release = '26'; ConsolePath = 'example/website/test/workload.guest.ubuntu.server.26.k8s.website.yml' }
        @{ Release = '24'; ConsolePath = 'book/test/ch02.website.k8s.dotnet.yml' }
        @{ Release = '24'; ConsolePath = 'book/test/ch02.website.k8s.dotnet.no-break.yml' }
    ) {
        $console = Get-Content -LiteralPath (Join-Path $script:BudgetProjectRoot $ConsolePath) -Raw | ConvertFrom-Yaml
        $consoleDeploy = @($console.workload | Where-Object { $_['action'] -eq 'fetchAndExecute' -and $_['text'] -like '*.workload.k8s.website.sh' })
        $consoleDeploy.Count | Should -Be 1
        $consoleDeploy[0].timeoutSeconds | Should -Be 1800
        foreach ($suffix in 'ssh', 'warm.ssh') {
            $relative = "example/website/test/workload.guest.ubuntu.server.$Release.k8s.website.$suffix.yml"
            $ssh = Get-Content -LiteralPath (Join-Path $script:BudgetProjectRoot $relative) -Raw | ConvertFrom-Yaml
            $sshDeploy = @($ssh.workload | Where-Object { $_['action'] -eq 'sshFetchAndExecute' -and $_['command'] -like '*.workload.k8s.website.sh' })
            $sshDeploy.Count | Should -Be 1
            $sshDeploy[0].command | Should -BeExactly $consoleDeploy[0].text
            $consoleDeploy[0].timeoutSeconds | Should -Be $sshDeploy[0].timeoutSeconds
        }
        # Input priming and prompt waits are independent of build/deployment time.
        $console.component[0].steps[0].snippet | Should -Be 'firstLoginPrime'
        $console.component[0].steps[1].timeoutSeconds | Should -Be 600
        $console.component[1].timeoutSeconds | Should -Be 90
        $console.component[2].snippet | Should -Be 'shellInputPrime'
    }
}

Describe 'Bundled example Docker process contract' -Skip:(-not $script:ProjectAvailable) {
    BeforeAll {
        $projectRoot = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'yuruna-project'
        $script:BuildModule = Import-Module (Join-Path $projectRoot 'tools/Example.Build.psm1') -Force -PassThru
        $script:NativePowerShell = (Get-Process -Id $PID).Path
        & $script:BuildModule {
            param($NativePath)
            $script:FixtureDocker = $NativePath
            # Substitute only command discovery; the process and stream work stays real.
            function script:Get-Command {
                param([string]$Name, [string]$CommandType, [string]$ErrorAction)
                if ($Name -ne 'docker' -or $CommandType -ne 'Application' -or $ErrorAction -ne 'SilentlyContinue') { throw 'Unexpected command discovery' }
                if ($script:FixtureDocker) { [pscustomobject]@{ Source = $script:FixtureDocker } }
            }
        } $script:NativePowerShell
        function Invoke-ProjectDockerFixture {
            param([string[]]$Arguments, [int]$TimeoutSeconds = 5)
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $records = @(& $script:BuildModule {
                param($Arguments, $TimeoutSeconds)
                Invoke-BoundedDocker -DockerArgs $Arguments -TimeoutSeconds $TimeoutSeconds
            } $Arguments $TimeoutSeconds *>&1)
            [pscustomobject]@{
                Codes = @($records | Where-Object { $_ -is [int] })
                Information = @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
                Warnings = @($records | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { [string]$_ })
                ElapsedSeconds = $clock.Elapsed.TotalSeconds
            }
        }
        function Write-ProjectDockerFixture {
            param([string]$Body)
            $path = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + ' fixture.ps1')
            [IO.File]::WriteAllText($path, $Body, [Text.UTF8Encoding]::new($false))
            return $path
        }
    }
    BeforeEach {
        & $script:BuildModule { param($NativePath) $script:FixtureDocker = $NativePath } $script:NativePowerShell
    }
    AfterAll {
        Remove-Module -ModuleInfo $script:BuildModule -Force
    }

    It 'preserves empty spaced quoted Unicode and trailing-backslash arguments' {
        $fixture = Write-ProjectDockerFixture -Body '[Console]::Out.Write((ConvertTo-Json -InputObject @($args) -Compress))'
        $values = @('', 'path with spaces', 'a"b', "caf`u{e9}", 'C:\folder with spaces\', '$literal;$(text)', '-option')
        $result = Invoke-ProjectDockerFixture -Arguments (@('-NoProfile', '-File', $fixture) + $values)
        $result.Codes.Count | Should -Be 1
        $result.Codes[0] | Should -Be 0
        $actual = @($result.Information -join "`n" | ConvertFrom-Json)
        $actual.Count | Should -Be $values.Count
        foreach ($index in 0..($values.Count - 1)) { $actual[$index] | Should -BeExactly $values[$index] }
    }

    It 'keeps stdout and stderr off the scalar success stream and preserves native failure' {
        $fixture = Write-ProjectDockerFixture -Body '[Console]::Out.WriteLine("standard output"); [Console]::Error.WriteLine("standard error"); exit 17'
        $result = Invoke-ProjectDockerFixture -Arguments @('-NoProfile', '-File', $fixture)
        $result.Codes.Count | Should -Be 1
        $result.Codes[0] | Should -Be 17
        $result.Information | Should -Contain 'standard output'
        $result.Information | Should -Contain 'standard error'
    }

    It 'drains both pipes concurrently past their operating-system buffer sizes' {
        $fixture = Write-ProjectDockerFixture -Body '[Console]::Out.Write(("o" * 131072)); [Console]::Error.Write(("e" * 131072))'
        $result = Invoke-ProjectDockerFixture -Arguments @('-NoProfile', '-File', $fixture)
        $result.Codes[0] | Should -Be 0
        ($result.Information | Where-Object { $_ -match '^o+$' }).Length | Should -Be 131072
        ($result.Information | Where-Object { $_ -match '^e+$' }).Length | Should -Be 131072
    }

    It 'closes stdin so a native input read receives EOF' {
        $fixture = Write-ProjectDockerFixture -Body 'if ([Console]::In.ReadToEnd().Length -ne 0) { exit 19 }; [Console]::Out.Write("input closed")'
        $result = Invoke-ProjectDockerFixture -Arguments @('-NoProfile', '-File', $fixture)
        $result.Codes[0] | Should -Be 0
        $result.Information | Should -Contain 'input closed'
    }

    It 'returns a failure when the Docker executable is missing' {
        & $script:BuildModule { $script:FixtureDocker = $null }
        $result = Invoke-ProjectDockerFixture -Arguments @('unused')
        $result.Codes.Count | Should -Be 1
        $result.Codes[0] | Should -Be 1
        $result.Warnings -join "`n" | Should -Match 'not found'
    }

    It 'returns a failure when native startup fails' {
        & $script:BuildModule { param($Path) $script:FixtureDocker = $Path } (Join-Path $TestDrive 'missing executable')
        $result = Invoke-ProjectDockerFixture -Arguments @('unused')
        $result.Codes[0] | Should -Be 1
        $result.Warnings -join "`n" | Should -Match 'Cannot start docker'
    }

    It 'times out and terminates the native child while retaining partial output' {
        $pidFile = Join-Path $TestDrive 'timeout.pid'
        $fixture = Write-ProjectDockerFixture -Body 'Set-Content -LiteralPath $args[0] -Value $PID; [Console]::Out.WriteLine("before timeout"); Start-Sleep -Seconds 30'
        $result = Invoke-ProjectDockerFixture -Arguments @('-NoProfile', '-File', $fixture, $pidFile) -TimeoutSeconds 2
        try {
            $result.Codes[0] | Should -Be 124
            $result.ElapsedSeconds | Should -BeLessThan 5
            $result.Information | Should -Contain 'before timeout'
            $childId = [int](Get-Content -LiteralPath $pidFile -Raw)
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        } finally {
            if (Test-Path -LiteralPath $pidFile) {
                Stop-Process -Id ([int](Get-Content -LiteralPath $pidFile -Raw)) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'bounds inherited output-pipe drain after the original native process exits' {
        $pidFile = Join-Path $TestDrive 'inherited.pid'
        $child = Write-ProjectDockerFixture -Body 'Set-Content -LiteralPath $args[0] -Value $PID; Start-Sleep -Seconds 30'
        $fixture = Write-ProjectDockerFixture -Body @'
$start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$start.UseShellExecute = $false
foreach ($value in @('-NoProfile', '-File', $args[0], $args[1])) { $start.ArgumentList.Add($value) }
$null = [Diagnostics.Process]::Start($start)
[Console]::Out.WriteLine('parent exited')
'@
        try {
            $result = Invoke-ProjectDockerFixture -Arguments @('-NoProfile', '-File', $fixture, $child, $pidFile) -TimeoutSeconds 8
            $result.Codes[0] | Should -Be 124
            $result.ElapsedSeconds | Should -BeLessThan 6
            $result.Information | Should -Contain 'parent exited'
        } finally {
            if (Test-Path -LiteralPath $pidFile) {
                Stop-Process -Id ([int](Get-Content -LiteralPath $pidFile -Raw)) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'terminates an attached descendant when its native parent times out' {
        $pidFile = Join-Path $TestDrive 'tree-child.pid'
        $parentPidFile = Join-Path $TestDrive 'tree-parent.pid'
        $child = Write-ProjectDockerFixture -Body 'Set-Content -LiteralPath $args[0] -Value $PID; Start-Sleep -Seconds 30'
        $fixture = Write-ProjectDockerFixture -Body @'
Set-Content -LiteralPath $args[2] -Value $PID
$start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$start.UseShellExecute = $false
foreach ($value in @('-NoProfile', '-File', $args[0], $args[1])) { $start.ArgumentList.Add($value) }
$null = [Diagnostics.Process]::Start($start)
Start-Sleep -Seconds 30
'@
        try {
            $result = Invoke-ProjectDockerFixture -Arguments @('-NoProfile', '-File', $fixture, $child, $pidFile, $parentPidFile) -TimeoutSeconds 3
            $result.Codes[0] | Should -Be 124
            $result.ElapsedSeconds | Should -BeLessThan 6
            foreach ($path in $pidFile, $parentPidFile) {
                Test-Path -LiteralPath $path | Should -BeTrue
                Get-Process -Id ([int](Get-Content -LiteralPath $path -Raw)) -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
        } finally {
            foreach ($path in $pidFile, $parentPidFile) {
                if (Test-Path -LiteralPath $path) { Stop-Process -Id ([int](Get-Content -LiteralPath $path -Raw)) -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'rejects a nonpositive timeout <Timeout>' -TestCases @(@{ Timeout = 0 }, @{ Timeout = -1 }) {
        param($Timeout)
        $invalidTimeout = $Timeout
        { Invoke-ProjectDockerFixture -Arguments @('-NoProfile', '-Command', 'exit 0') -TimeoutSeconds $invalidTimeout } | Should -Throw
    }

    It 'handles the largest Int32 timeout without overflowing milliseconds' {
        $result = Invoke-ProjectDockerFixture -Arguments @('-NoProfile', '-Command', 'exit 0') -TimeoutSeconds ([int]::MaxValue)
        $result.Codes[0] | Should -Be 0
        $result.ElapsedSeconds | Should -BeLessThan 5
    }
}
