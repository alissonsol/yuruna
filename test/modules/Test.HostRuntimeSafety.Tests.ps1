<#PSScriptInfo
.VERSION 2026.09.30
.GUID 424882ac-09a5-499f-af1e-64e5b6e9bf94
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runtime safety pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    $script:TestRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
    foreach ($name in @('Test.HostAutomationState','Test.SingleInstance','Test.ServiceVm','Test.InnerSpawn','Test.HostMetricsExporter')) {
        Import-Module (Join-Path $PSScriptRoot ($name + '.psm1')) -Force -Global -DisableNameChecking
    }
    function Get-RuntimeSafetyAst {
        param([string]$Path)
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        if ($errors) { throw ($errors -join '; ') }
        return $ast
    }
    function Get-RuntimeSafetyFunction {
        param([string]$Path, [string]$Name)
        $ast = Get-RuntimeSafetyAst $Path
        $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
        if (-not $fn) { throw "Missing function: $Name" }
        return [scriptblock]::Create($fn.Extent.Text)
    }
    . (Get-RuntimeSafetyFunction -Path "$script:TestRoot/New-LocalTestUser.ps1" -Name Read-NewPassword)
}

Describe 'account bootstrap protects existing identities' {
    It 'rejects a confirmation that differs only in letter case' {
        $script:PasswordReads = 0
        Mock Read-Host {
            $script:PasswordReads++
            $text = if ($script:PasswordReads -eq 1) { 'Synthetic-Secret-1' } else { 'synthetic-secret-1' }
            $secure = [Security.SecureString]::new()
            foreach ($c in $text.ToCharArray()) { $secure.AppendChar($c) }
            return $secure
        }
        { Read-NewPassword -Name fixture } | Should -Throw '*did not match*'
    }
    It 'places every password and declaration refusal before account deletion' {
        $ast = Get-RuntimeSafetyAst "$script:TestRoot/New-LocalTestUser.ps1"
        $remove = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Remove-OsUser' }, $true)
        $read = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$DeclaredIn' }, $true)
        $password = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-NewPassword' }, $true)
        $macRefusal = $ast.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -like '*$IsMacOS -and $HasPassword*' }, $true)
        foreach ($preflight in @($read, $password, $macRefusal)) {
            $preflight | Should -Not -BeNullOrEmpty
            $preflight.Extent.EndOffset | Should -BeLessThan $remove.Extent.StartOffset
        }
    }
    It 'retains script-level name bindings across self elevation' {
        $ast = Get-RuntimeSafetyAst "$script:TestRoot/New-LocalTestUser.ps1"
        $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SelfElevation' }, $true)
        $fn.Extent.Text | Should -Match 'UserScriptBoundParameters.ContainsKey\(''FirstName''\)'
        $fn.Extent.Text | Should -Match 'UserScriptBoundParameters.ContainsKey\(''LastName''\)'
    }
    It 'resolves a warm-path target before the concurrent VM sweep' {
        $ast = Get-RuntimeSafetyAst "$script:TestRoot/Debug-TestSequence.ps1"
        $retarget = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$VMName' -and $node.Right.Extent.Text -eq '$requiredSnapshotId' }, $true)
        $sweep = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Stop-ConcurrentVM' -and $node.Extent.Text -match '-ExceptVmName' }, $true)
        $retarget.Extent.EndOffset | Should -BeLessThan $sweep.Extent.StartOffset
    }
}

Describe 'localized power setting evidence' {
    It 'extracts distinct AC and DC indices from <Locale> labels' -ForEach @(
        @{ Locale='English'; Ac='Current AC Power Setting Index'; Dc='Current DC Power Setting Index' },
        @{ Locale='Portuguese'; Ac="`u{cd}ndice da Configura`u{e7}`u{e3}o de Energia CA Atual"; Dc="`u{cd}ndice da Configura`u{e7}`u{e3}o de Energia CC Atual" },
        @{ Locale='Chinese'; Ac="`u{5f53}`u{524d}`u{4ea4}`u{6d41}`u{7535}`u{6e90}`u{8bbe}`u{7f6e}`u{7d22}`u{5f15}"; Dc="`u{5f53}`u{524d}`u{76f4}`u{6d41}`u{7535}`u{6e90}`u{8bbe}`u{7f6e}`u{7d22}`u{5f15}" }
    ) {
        $output = @('Minimum: 0x00000000','Maximum: 0xffffffff',"${Ac}: 0x00000258", "${Dc}: 0x0000012c")
        ConvertFrom-YurunaPowerSettingIndex -Output $output -Scheme AC | Should -Be 600
        ConvertFrom-YurunaPowerSettingIndex -Output $output -Scheme DC | Should -Be 300
    }
    It 'keeps an unreadable setting unknown' {
        ConvertFrom-YurunaPowerSettingIndex -Output @('command failed') | Should -BeNullOrEmpty
    }
}

Describe 'runner reclamation follows process generations' {
    It 'prunes children that predate a recycled parent without walking their descendants' {
        $rows = @(
            [pscustomobject]@{ Pid=100; ParentPid=1; StartTimeUnixMs=50000L },
            [pscustomobject]@{ Pid=101; ParentPid=100; StartTimeUnixMs=10000L },
            [pscustomobject]@{ Pid=102; ParentPid=101; StartTimeUnixMs=51000L },
            [pscustomobject]@{ Pid=103; ParentPid=100; StartTimeUnixMs=51000L }
        )
        $result = Resolve-YurunaRunnerProcessTarget -ProcessTable $rows -VerifiedRoot @($rows[0])
        ($result.Descendants.Pid -join ',') | Should -Be '103,100'
        $result.ReasonRecords.Code | Should -Contain 'child-start-mismatch'
    }
    It 'does not trust an inner PID without matching start-time ownership' {
        Mock Stop-YurunaProcessTree -ModuleName Test.SingleInstance { }
        Mock Get-Process -ModuleName Test.SingleInstance { $null }
        Mock Get-YurunaRunnerRecordState -ModuleName Test.SingleInstance { [pscustomobject]@{ State='DeadOrRecycled'; Pid=12345 } }
        $runtime = Join-Path $TestDrive 'runner'
        $null = New-Item -ItemType Directory -Path $runtime
        Set-Content "$runtime/inner.pid" 12345
        Stop-StaleRunner -ProcessId 12344 -RuntimeDir $runtime -TestRoot $TestDrive -WaitForExitMs 0 -Confirm:$false
        Should -Invoke Stop-YurunaProcessTree -ModuleName Test.SingleInstance -Times 0 -Exactly -ParameterFilter { $ProcessId -eq 12345 }
        Should -Invoke Get-YurunaRunnerRecordState -ModuleName Test.SingleInstance -Times 1 -Exactly -ParameterFilter { $StartFile -like '*[/\]inner.start' -and $ExpectedScriptPath -like '*[/\]Invoke-TestRunnerInnerLoop.ps1' }
    }
}

Describe 'native service invocation preserves failure and argument boundaries' {
    It 'records failed service VM stops separately from successful stops' {
        Mock Test-Path -ModuleName Test.HostAutomationState { $true }
        Mock pwsh -ModuleName Test.HostAutomationState { $global:LASTEXITCODE = 7 }
        $cmdlet = [pscustomobject]@{}
        $cmdlet | Add-Member ScriptMethod ShouldProcess { param($target,$action) return [bool]($target -and $action) }
        $restored = [Collections.Generic.List[string]]::new()
        $skipped = [Collections.Generic.List[string]]::new()
        Stop-YurunaServiceVMSet -RepoRoot $TestDrive -Cmdlet $cmdlet -Restored $restored -Skipped $skipped
        $restored.Count | Should -Be 0
        $skipped.Count | Should -Be 4
        $skipped[0] | Should -Match 'exit 7'
    }
    It 'quotes a winget log path as one native argument' {
        Mock Start-Process -ModuleName Test.HostMetricsExporter {
            $process = [pscustomobject]@{ Id=12345; ExitCode=0 }
            $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $milliseconds -gt 0 }
            return $process
        }
        & (Get-Module Test.HostMetricsExporter) { Invoke-YurunaWingetInstall -WingetPath 'C:\Program Files\winget.exe' -PackageId fixture -TimeoutSec 10 -LogPath 'C:\Users\Test User\install log.txt' -Confirm:$false } | Out-Null
        Should -Invoke Start-Process -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -ParameterFilter { $ArgumentList -match '"C:\\Users\\Test User\\install log.txt"' }
    }
    It 'waits for a VM address before configuring the shared NAT forwarder' {
        $ast = Get-RuntimeSafetyAst "$script:TestRoot/service/Start-PoolControlServiceVM.ps1"
        $wait = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Wait-VMIp' }, $true)
        $forward = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-PortMap' }, $true)
        $wait.Extent.EndOffset | Should -BeLessThan $forward.Extent.StartOffset
    }
}
