<#PSScriptInfo
.VERSION 2026.11.16
.GUID 42bac1db-129d-4eb2-b959-5f0109738abb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test windows installer winget powershell upgrade version pester
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
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Test-local Get-Module stands in for the module list the installer reads.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted installer functions read fixture variables through dynamic scope.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stubs keep the signatures the installer calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fixture builders write only under TestDrive.')]
[CmdletBinding()]
param()
<#
.SYNOPSIS
    The Windows installer moves what it manages to the newest version its
    source offers and says what is still behind.
.DESCRIPTION
    A run under pwsh cannot upgrade the pwsh it runs in, so it leaves the
    upgrade to a Windows PowerShell script that waits for it to exit. The
    functions are taken from install/windows.hyper-v.ps1 by name. The helper
    script runs for real on Linux, against a fake winget and a fake pwsh on
    PATH; those shell fakes cannot run on Windows, so those cases skip there.
#>
BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:Installer = Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1'
    foreach ($name in 'ConvertFrom-WingetListRow', 'Get-PwshUpgradePlan', 'New-PwshUpgradeHelperScript', 'Get-LastPwshUpgradeResult',
        'Format-NewerVersionReport', 'Get-YurunaModulePinVersion', 'Install-YurunaYamlModule') {
        $ast = Get-YurunaTestFunctionAst -Path $script:Installer -Name $name
        if (-not $ast) { throw "install/windows.hyper-v.ps1 no longer defines $name." }
        . ([scriptblock]::Create($ast.Extent.Text))
    }
    $script:InstallerAst = Get-YurunaTestFileAst -Path $script:Installer
    $script:Pwsh = (Get-Process -Id $PID).Path

    function New-UpgradeFake {
        # A fake winget that records its arguments, whether the waited-on
        # process was still alive when it ran, and exits with the given code;
        # a fake pwsh that reports a version, or records a handoff window.
        param([string]$Root, [int]$WingetExit = 0, [int]$WatchPid = 0)
        $bin = Join-Path $Root 'bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        $winget = Join-Path $bin 'winget'
        Set-Content -LiteralPath $winget -Value @"
#!/bin/sh
printf '%s\n' "`$*" >> '$Root/winget.args'
if [ $WatchPid -gt 0 ] && kill -0 $WatchPid 2>/dev/null; then echo alive >> '$Root/winget.args'; fi
echo 'Successfully installed'
exit $WingetExit
"@
        $pwsh = Join-Path $bin 'pwsh'
        Set-Content -LiteralPath $pwsh -Value @"
#!/bin/sh
case "`$*" in
  *-EncodedCommand*) printf '%s\n' "`$*" >> '$Root/handoff.args' ;;
  *) echo '7.6.9' ;;
esac
"@
        & chmod +x $winget $pwsh
        return $bin
    }

    function Invoke-UpgradeHelper {
        param([string]$Root, [string]$Text, [string]$Bin)
        $file = Join-Path $Root 'upgrade-powershell.ps1'
        [IO.File]::WriteAllText($file, $Text)
        $prior = Save-YurunaTestEnvironment -Name 'PATH'
        try {
            $env:PATH = $Bin + [IO.Path]::PathSeparator + $prior['PATH']
            $null = & $script:Pwsh -NoLogo -NoProfile -File $file 2>&1
            return $LASTEXITCODE
        } finally {
            Restore-YurunaTestEnvironment -Saved $prior
        }
    }
}

Describe 'winget list rows (Windows installer)' {
    It 'reads the installed and the available version from a row whose headers are in another language' {
        $row = ConvertFrom-WingetListRow -Id 'Microsoft.PowerShell' -Line @(
            '   - ', '   \ ',
            'Nome                Id                    Versao   Disponivel Origem',
            '-----------------------------------------------------------------------',
            'PowerShell 7-x64    Microsoft.PowerShell  7.6.6.0  7.6.9.0    winget')
        Assert-Equal '7.6.6.0' $row.Installed
        Assert-Equal '7.6.9.0' $row.Available
    }

    It 'reads a row with nothing newer as current' {
        $row = ConvertFrom-WingetListRow -Id 'Git.Git' -Line @('Git  Git.Git  2.56.0.4  winget')
        Assert-Equal '2.56.0.4' $row.Installed
        Assert-Null $row.Available 'no Available column value means winget has nothing newer'
    }

    It 'keeps a version winget can only bound as one value' {
        $row = ConvertFrom-WingetListRow -Id 'Vendor.App' -Line @('Some App  Vendor.App  < 1.2.3  1.3.0  winget')
        Assert-Equal '< 1.2.3' $row.Installed
        Assert-Equal '1.3.0' $row.Available
    }

    It 'answers nothing when <Case>' -TestCases @(
        @{ Case = 'the package is not listed'; Line = @('No installed package found matching input criteria.') }
        @{ Case = 'only a longer id starts with the one asked for'; Line = @('PowerShell Preview  Microsoft.PowerShell.Preview  7.7.0.1  winget') }
        @{ Case = 'winget printed nothing'; Line = @() }
    ) {
        param($Case, $Line)
        Assert-Null (ConvertFrom-WingetListRow -Id 'Microsoft.PowerShell' -Line $Line) $Case
    }
}

Describe 'PowerShell upgrade after a run under pwsh' {
    It 'plans the upgrade when winget offers a newer PowerShell to a run under pwsh' {
        $plan = Get-PwshUpgradePlan -Edition 'Core' -Listed ([pscustomobject]@{ Installed = '7.6.6.0'; Available = '7.6.9.0' })
        Assert-Equal '7.6.6.0' $plan.From
        Assert-Equal '7.6.9.0' $plan.To
    }

    It 'plans nothing when <Case>' -TestCases @(
        @{ Case = 'the run is under Windows PowerShell, whose bootstrap upgrades pwsh'; Edition = 'Desktop'; Listed = [pscustomobject]@{ Installed = '7.6.6.0'; Available = '7.6.9.0' } }
        @{ Case = 'winget has nothing newer'; Edition = 'Core'; Listed = [pscustomobject]@{ Installed = '7.6.9.0'; Available = $null } }
        @{ Case = 'winget did not list PowerShell'; Edition = 'Core'; Listed = $null }
    ) {
        param($Case, $Edition, $Listed)
        Assert-Null (Get-PwshUpgradePlan -Edition $Edition -Listed $Listed) $Case
    }

    It 'writes a helper script that Windows PowerShell 5.1 can parse and that keeps quoted paths whole' {
        $text = New-PwshUpgradeHelperScript -InstallerProcessId 4242 -UpgradeLogPath "C:\ProgramData\Yuruna\logs\it's.pwsh-upgrade.log" `
            -From '7.6.6.0' -To '7.6.9.0' -HandoffCommand 'QQBCAEMA' -HelperDirectory 'C:\ProgramData\yuruna\pwsh-upgrade-x'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        Assert-Equal 0 @($errors).Count 'the helper parses'
        $newer = @($tokens | Where-Object { $_.Kind -in 'QuestionDot', 'QuestionLBracket', 'QuestionQuestion', 'QuestionQuestionEquals', 'AndAnd', 'OrOr', 'QuestionMark' })
        Assert-Equal 0 $newer.Count 'nothing PowerShell 5.1 lacks'
        $log = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$log' }, $true)
        Assert-Equal "C:\ProgramData\Yuruna\logs\it's.pwsh-upgrade.log" $log.Right.Expression.Value
        Assert-Match "upgrade --id 'Microsoft.PowerShell' --exact --silent --source winget" $text 'it upgrades the one package, from the winget source'
    }

    It 'waits for the installer to exit, then upgrades and records the result' -Skip:$IsWindows {
        $root = Join-Path $TestDrive 'waits'
        $installer = Start-Process -FilePath 'sleep' -ArgumentList '2' -PassThru
        $bin = New-UpgradeFake -Root $root -WatchPid $installer.Id
        $log = Join-Path $root 'install.pwsh-upgrade.log'
        $text = New-PwshUpgradeHelperScript -InstallerProcessId $installer.Id -UpgradeLogPath $log -From '7.6.6.0' -To '7.6.9.0' -WaitSeconds 60 -PwshName (Join-Path $bin 'pwsh')
        $code = Invoke-UpgradeHelper -Root $root -Text $text -Bin $bin
        Assert-Equal 0 $code
        $calls = @(Get-Content -LiteralPath (Join-Path $root 'winget.args'))
        Assert-Equal 'upgrade --id Microsoft.PowerShell --exact --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity' $calls[0]
        Assert-False ($calls -contains 'alive') 'winget ran only after the installer had exited'
        $lines = @(Get-Content -LiteralPath $log)
        Assert-Match 'PowerShell 7\.6\.6\.0 -> 7\.6\.9\.0: waiting for the installer \(process \d+\) to exit$' $lines[0]
        Assert-Match '\sRESULT: upgraded \(winget exit 0\); pwsh is now 7\.6\.9$' $lines[-1]
        Assert-False (Test-Path -LiteralPath (Join-Path $root 'handoff.args')) 'no window was asked for'
    }

    It 'does not upgrade while the installer is still running past its bound' -Skip:$IsWindows {
        $root = Join-Path $TestDrive 'bound'
        $installer = Start-Process -FilePath 'sleep' -ArgumentList '60' -PassThru
        try {
            $bin = New-UpgradeFake -Root $root
            $log = Join-Path $root 'install.pwsh-upgrade.log'
            $text = New-PwshUpgradeHelperScript -InstallerProcessId $installer.Id -UpgradeLogPath $log -From '7.6.6.0' -To '7.6.9.0' -WaitSeconds 1 -PwshName (Join-Path $bin 'pwsh')
            $code = Invoke-UpgradeHelper -Root $root -Text $text -Bin $bin
            Assert-Equal 1 $code
            Assert-False (Test-Path -LiteralPath (Join-Path $root 'winget.args')) 'winget never ran'
            Assert-Match '\sRESULT: not run -- the installer was still running after' (@(Get-Content -LiteralPath $log)[-1])
        } finally {
            Stop-Process -Id $installer.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'names a failed upgrade, then opens the next-steps window and removes its folder' -Skip:$IsWindows {
        $root = Join-Path $TestDrive 'failed'
        $bin = New-UpgradeFake -Root $root -WingetExit 1
        $helperDir = Join-Path $root 'helper'
        $null = New-Item -ItemType Directory -Path $helperDir -Force
        $log = Join-Path $root 'install.pwsh-upgrade.log'
        # A process id that has already exited: the helper does not wait.
        $gone = Start-Process -FilePath 'true' -PassThru
        $gone.WaitForExit()
        $text = New-PwshUpgradeHelperScript -InstallerProcessId $gone.Id -UpgradeLogPath $log -From '7.6.6.0' -To '7.6.9.0' `
            -HandoffCommand 'SABJAA==' -HelperDirectory $helperDir -PwshName (Join-Path $bin 'pwsh')
        $null = Invoke-UpgradeHelper -Root $root -Text $text -Bin $bin
        Assert-Match '\sRESULT: failed \(winget exit 1\); pwsh is now 7\.6\.9$' (@(Get-Content -LiteralPath $log)[-1])
        # The window is started, not waited on: give the fake a moment to record it.
        $handoff = Join-Path $root 'handoff.args'
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $handoff) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert-Equal '-NoExit -NoLogo -EncodedCommand SABJAA==' (@(Get-Content -LiteralPath $handoff)[0])
        Assert-False (Test-Path -LiteralPath $helperDir) 'the helper removes its folder'
    }

    It 'the next run reads the result the newest upgrade log ends with' {
        $dir = Join-Path $TestDrive 'logs'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $older = Join-Path $dir 'windows.hyper-v.install.20261101-000000.pwsh-upgrade.log'
        $newer = Join-Path $dir 'windows.hyper-v.install.20261108-000000.pwsh-upgrade.log'
        Set-Content -LiteralPath $older -Value @('2026-11-01T00:00:00Z waiting', '2026-11-01T00:01:00Z RESULT: failed (winget exit 1); pwsh is now 7.6.6')
        Set-Content -LiteralPath $newer -Value @('2026-11-08T00:00:00Z waiting', '2026-11-08T00:01:00Z RESULT: upgraded (winget exit 0); pwsh is now 7.6.9')
        (Get-Item -LiteralPath $older).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-7)
        $last = Get-LastPwshUpgradeResult -LogDirectory $dir
        Assert-Equal $newer $last.Path
        Assert-Equal 'RESULT: upgraded (winget exit 0); pwsh is now 7.6.9' $last.Result
        Set-Content -LiteralPath $newer -Value @('2026-11-08T00:00:00Z waiting')
        Assert-Match '^no RESULT line' (Get-LastPwshUpgradeResult -LogDirectory $dir).Result 'an unfinished upgrade says so'
        Assert-Null (Get-LastPwshUpgradeResult -LogDirectory (Join-Path $TestDrive 'none')) 'no folder, nothing to read'
    }

    It 'with an upgrade scheduled, the next-steps window opens after the upgrade, not before it' {
        $branch = $script:InstallerAst.Find({
                param($n)
                $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -ge 2 -and
                $n.Clauses[0].Item1.Extent.Text -eq '$script:PwshUpgrade' -and $n.Clauses[0].Item2.Extent.Text -match 'HandoffCommand = \$encoded'
            }, $true)
        Assert-NotNull $branch 'the handoff decides on the scheduled upgrade first'
        $opens = { param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process' -and $n.Extent.Text -match "'-NoExit'" }
        Assert-Null ($branch.Clauses[0].Item2.Find($opens, $true)) 'no window opens while the upgrade is pending'
        Assert-NotNull ($branch.Clauses[1].Item2.Find($opens, $true)) 'without an upgrade the window opens as before'
    }
}

Describe 'Newer versions available (Windows installer)' {
    It 'lists each tool with a newer version and why, and a lookup that could not answer as unknown' {
        $lines = Format-NewerVersionReport -Entry @(
            [pscustomobject]@{ Name = 'PowerShell 7'; Installed = '7.6.6.0'; Available = '7.6.9.0'; Note = 'upgrade runs once this installer exits' }
            [pscustomobject]@{ Name = 'Git'; Installed = '2.56.0.4'; Available = $null; Note = $null }
            [pscustomobject]@{ Name = 'QEMU'; Unknown = $true; Note = 'winget list did not report it' }
        )
        Assert-Equal 3 @($lines).Count
        Assert-Equal 'Newer versions available' $lines[0]
        Assert-Equal '  PowerShell 7: 7.6.6.0 -> 7.6.9.0 (upgrade runs once this installer exits)' $lines[1]
        Assert-Equal '  QEMU: unknown (winget list did not report it)' $lines[2]
    }

    It 'says so in one line when every tool is at the newest version' {
        $lines = @(Format-NewerVersionReport -Entry @([pscustomobject]@{ Name = 'Git'; Installed = '2.56.0.4'; Available = $null }))
        Assert-Equal 2 $lines.Count
        Assert-Match '^  none: ' $lines[1]
    }

    It 'covers every package the installer keeps current, and PowerShell' {
        $installed = @($script:InstallerAst.FindAll({
                    param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Install-WingetPackage'
                }, $true) | ForEach-Object {
                $elements = $_.CommandElements
                for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                    if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Id') { $elements[$i + 1].Value }
                }
            } | Sort-Object -Unique)
        $listAst = $script:InstallerAst.Find({
                param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:YurunaWingetReportPackage'
            }, $true)
        $reported = @($listAst.Right.FindAll({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true) |
                ForEach-Object { $_.SafeGetValue()['Id'] } | Sort-Object -Unique)
        Assert-True ($installed -contains 'Microsoft.PowerShell') 'the 5.x stage still installs PowerShell through the same function'
        Assert-Equal ($installed -join ',') ($reported -join ',')
    }

    It 'reads a pinned version from another script''s pin table without running it' {
        $fixture = Join-Path $TestDrive 'Install-TestModule.ps1'
        Set-Content -LiteralPath $fixture -Value @'
throw 'this file must not run'
$script:YurunaGalleryModulePin = @{
    'PSScriptAnalyzer' = @{ Version = '1.25.0'; Sha512 = 'x' }
}
'@
        Assert-Equal '1.25.0' (Get-YurunaModulePinVersion -Path $fixture -Name 'PSScriptAnalyzer')
        Assert-Null (Get-YurunaModulePinVersion -Path $fixture -Name 'Pester') 'a module with no pin'
        Assert-Null (Get-YurunaModulePinVersion -Path (Join-Path $TestDrive 'absent.ps1') -Name 'PSScriptAnalyzer') 'no file'
        Assert-Match '^\d+\.\d+\.\d+$' (Get-YurunaModulePinVersion -Path (Join-Path $script:RepoRoot 'tools/Install-TestModule.ps1') -Name 'PSScriptAnalyzer') `
            'the real pin table reads too'
    }
}

Describe 'powershell-yaml is raised to its pin (Windows installer)' {
    BeforeEach {
        $script:YurunaGalleryModulePin = @{ 'powershell-yaml' = @{ Version = '0.4.12'; Sha512 = 'x' } }
        $script:Installed = @()
        $script:Pinned = 0
        $script:Issue = [System.Collections.Generic.List[string]]::new()
        $script:Warned = [System.Collections.Generic.List[string]]::new()
        $script:InstallThrows = $false
        function Get-Module { param([switch]$ListAvailable, [string]$Name, $ErrorAction) $script:Installed }
        function Install-YurunaPinnedGalleryModule { param([string]$Name) $script:Pinned++; if ($script:InstallThrows) { throw 'gallery unreachable' } }
        function Write-Step { param([string]$m) }
        function Write-Warn { param([string]$m) $script:Warned.Add($m) }
        function Add-InstallIssue { param([string]$m) $script:Issue.Add($m) }
    }

    It 'installs the pin when <Case>' -TestCases @(
        @{ Case = 'an older copy is installed'; Have = @('0.4.7'); Expected = 1 }
        @{ Case = 'none is installed'; Have = @(); Expected = 1 }
        @{ Case = 'the pin is installed already'; Have = @('0.4.12'); Expected = 0 }
        @{ Case = 'a newer copy is installed'; Have = @('0.4.7', '0.5.0'); Expected = 0 }
    ) {
        param($Case, $Have, $Expected)
        $script:Installed = @($Have | ForEach-Object { [pscustomobject]@{ Name = 'powershell-yaml'; Version = [version]$_ } })
        Install-YurunaYamlModule
        Assert-Equal $Expected $script:Pinned $Case
    }

    It 'names the older copy that stays in use when the pin cannot be installed' {
        $script:Installed = @([pscustomobject]@{ Name = 'powershell-yaml'; Version = [version]'0.4.7' })
        $script:InstallThrows = $true
        Install-YurunaYamlModule
        Assert-Match 'the older 0\.4\.7 stays in use' $script:Issue[0]
        Assert-False (($script:Warned -join "`n") -match 'refuse to run') 'the runner still has a powershell-yaml to load'
    }
}
