<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 427c26ad-413b-4523-82d5-2c48297ba74d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest installer jdk macos pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

BeforeDiscovery {
    $script:CanRunBash = -not $IsWindows -and $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $script:Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $source = Get-Content (Join-Path $script:RepoRoot 'guest/windows.11/windows.11.code.ps1') -Raw
    $start = $source.IndexOf('# --- REGION: Install JDK')
    $end = $source.IndexOf('# --- REGION: Install .NET SDK', $start)
    if ($start -lt 0 -or $end -lt 0) { throw 'JDK installer phase was not found' }
    $script:JdkPhase = $source.Substring($start, $end - $start)
    $start = $source.IndexOf('# --- REGION: Install .NET SDK')
    $end = $source.IndexOf("[Environment]::SetEnvironmentVariable('DOTNET_ROOT'", $start)
    if ($start -lt 0 -or $end -lt 0) { throw '.NET installer outcome boundary was not found' }
    $script:DotnetPhase = $source.Substring($start, $end - $start)

    # --- REGION: Invoke-JdkOutcomeFixture
    function Invoke-JdkOutcomeFixture {
        <# Runs the shipped JDK phase with private files and mocked native installers. #>
        param([string]$Mode = 'healthy', [int]$Code = 0, [int]$Native = 9)
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $guestTemp = Join-Path $fixture "guest's temp"
        $null = New-Item -ItemType Directory -Path $guestTemp -Force
        $installer = Join-Path $guestTemp 'temurin-jdk.msi'
        if ($Mode -eq 'directory') {
            $null = New-Item -ItemType Directory -Path $installer
            Set-Content -LiteralPath (Join-Path $installer 'keep.txt') -Value 'preserve unexpected directory'
        } else { Set-Content -LiteralPath $installer -Value 'stale installer' }
        $prefix = @'
$script:Calls = [ordered]@{ api=0; downloads=0; installs=0; uri=''; arguments=''; wait=$false; passThru=$false; downloadErrorAction=''; installErrorAction='' }
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Property)
    if ($ClassName -ne 'Win32_Processor' -or $Property -ne 'Architecture') { throw 'Native architecture query changed' }
    if ($env:YURUNA_INSTALL_MODE -eq 'query-error') { Write-Error 'fixture native query failed'; return }
    if ($env:YURUNA_INSTALL_MODE -eq 'empty-query') { return }
    if ($env:YURUNA_INSTALL_MODE -eq 'missing-architecture') { return [pscustomobject]@{ DeviceID='fixture' } }
    [pscustomobject]@{ Architecture=[int]$env:YURUNA_INSTALL_NATIVE }
}
function Invoke-RestMethod {
    [CmdletBinding()]
    param([switch]$UseBasicParsing, [string]$Uri)
    $script:Calls.api++
    if ($Uri -ne 'https://api.adoptium.net/v3/info/available_releases') { throw 'LTS discovery URL changed' }
    if ($env:YURUNA_INSTALL_MODE -eq 'api-error') { Write-Error 'fixture LTS discovery failed'; return }
    [pscustomobject]@{ most_recent_lts=25 }
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
    $script:Calls.downloads++
    $script:Calls.uri=$Uri
    $script:Calls.downloadErrorAction=[string]$PSBoundParameters.ErrorAction
    if (Test-Path -LiteralPath $OutFile) { throw 'Stale installer was not removed before transfer' }
    if ($env:YURUNA_INSTALL_MODE -eq 'missing-download') { return }
    if ($env:YURUNA_INSTALL_MODE -eq 'empty-download') { [IO.File]::WriteAllText($OutFile, ''); return }
    [IO.File]::WriteAllText($OutFile, 'fixture downloaded bytes')
    if ($env:YURUNA_INSTALL_MODE -eq 'download-error') { Write-Error 'fixture transfer failed after bytes'; return }
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string]$ArgumentList, [switch]$Wait, [switch]$PassThru)
    $script:Calls.installs++
    $script:Calls.arguments=$ArgumentList
    $script:Calls.wait=[bool]$Wait
    $script:Calls.passThru=[bool]$PassThru
    $script:Calls.installErrorAction=[string]$PSBoundParameters.ErrorAction
    if ($FilePath -ne 'msiexec.exe') { throw 'Unexpected installer executable' }
    if ($env:YURUNA_INSTALL_MODE -eq 'launch-error') { Write-Error 'fixture installer could not start'; return }
    if ($env:YURUNA_INSTALL_MODE -eq 'null-process') { return }
    if ($env:YURUNA_INSTALL_MODE -eq 'missing-exit-code') { return [pscustomobject]@{ Id=123 } }
    [pscustomobject]@{ ExitCode=[int]$env:YURUNA_INSTALL_CODE }
}
'@
        $suffix = @'
Write-Output 'would-install-next-package'
} finally { $script:Calls | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:YURUNA_INSTALL_RESULT }
'@
        $entry = Join-Path $fixture 'fixture.ps1'
        $callsPath = Join-Path $fixture 'calls.json'
        Set-Content -LiteralPath $entry -Value ($prefix + "`ntry {`n" + $script:JdkPhase + "`n" + $suffix) -Encoding utf8NoBOM
        $result = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-File', $entry) -TimeoutSeconds 15 `
            -Environment @{ TEMP=$guestTemp; YURUNA_INSTALL_MODE=$Mode; YURUNA_INSTALL_CODE=[string]$Code; YURUNA_INSTALL_NATIVE=[string]$Native; YURUNA_INSTALL_RESULT=$callsPath }
        [pscustomobject]@{ Process=$result; Calls=(Get-Content -LiteralPath $callsPath -Raw | ConvertFrom-Json); Installer=$installer }
    }

    # --- REGION: Invoke-DotnetOutcomeFixture
    function Invoke-DotnetOutcomeFixture {
        <# Exercises the actual download/invocation gate before machine environment writes. #>
        param([string]$Mode = 'healthy')
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $guestTemp = Join-Path $fixture "guest's temp"
        $null = New-Item -ItemType Directory -Path $guestTemp -Force
        $installer = Join-Path $guestTemp 'dotnet-install.ps1'
        if ($Mode -eq 'directory') {
            $null = New-Item -ItemType Directory -Path $installer
            Set-Content -LiteralPath (Join-Path $installer 'keep.txt') -Value 'preserve unexpected directory'
        } else { Set-Content -LiteralPath $installer -Value 'stale installer' }
        $prefix = @'
$ErrorActionPreference = 'Continue'
$global:LASTEXITCODE = 73
$script:Calls = [ordered]@{ downloads=0; uri=''; downloadErrorAction='' }
function Get-Item {
    [CmdletBinding()]
    param([string]$LiteralPath)
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    if ($env:YURUNA_INSTALL_MODE -eq 'missing-launch') {
        $length = $item.Length
        Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        return [pscustomobject]@{ Length=$length }
    }
    return $item
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
    $script:Calls.downloads++
    $script:Calls.uri=$Uri
    $script:Calls.downloadErrorAction=[string]$PSBoundParameters.ErrorAction
    if (Test-Path -LiteralPath $OutFile) { throw 'Stale installer was not removed before transfer' }
    if ($env:YURUNA_INSTALL_MODE -eq 'missing-download') { return }
    if ($env:YURUNA_INSTALL_MODE -eq 'empty-download') { [IO.File]::WriteAllText($OutFile, ''); return }
    $payload = @"
[CmdletBinding()]
param([string]`$Channel, [string]`$InstallDir)
if (`$Channel -ne 'LTS' -or `$InstallDir -ne (Join-Path `$env:ProgramFiles 'dotnet')) { throw 'SDK install contract changed' }
@{ Channel=`$Channel; Directory=`$InstallDir; PriorExitCode=`$global:LASTEXITCODE } | ConvertTo-Json -Compress | Set-Content -LiteralPath `$env:YURUNA_INSTALL_LAUNCH
switch (`$env:YURUNA_INSTALL_MODE) {
    'exit-error' { exit 17 }
    'launch-error' { throw 'fixture SDK installer threw' }
    'command-error' { Write-Error 'fixture SDK installer command failed'; return }
    'explicit-success' { exit 0 }
}
"@
    [IO.File]::WriteAllText($OutFile, $payload)
    if ($env:YURUNA_INSTALL_MODE -eq 'download-error') { Write-Error 'fixture SDK transfer failed after bytes'; return }
}
'@
        $suffix = @'
Write-Output 'would-register-machine-environment'
Write-Output '<<< .NET SDK installation complete.'
} finally { $script:Calls | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:YURUNA_INSTALL_RESULT }
'@
        $entry = Join-Path $fixture 'fixture.ps1'
        $callsPath = Join-Path $fixture 'calls.json'
        $launchPath = Join-Path $fixture 'launch.json'
        Set-Content -LiteralPath $entry -Value ($prefix + "`ntry {`n" + $script:DotnetPhase + "`n" + $suffix) -Encoding utf8NoBOM
        $result = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-File', $entry) -TimeoutSeconds 15 `
            -Environment @{ TEMP=$guestTemp; ProgramFiles=$fixture; YURUNA_INSTALL_MODE=$Mode; YURUNA_INSTALL_RESULT=$callsPath; YURUNA_INSTALL_LAUNCH=$launchPath }
        $launch = if (Test-Path -LiteralPath $launchPath) { Get-Content -LiteralPath $launchPath -Raw | ConvertFrom-Json } else { $null }
        [pscustomobject]@{ Process=$result; Calls=(Get-Content -LiteralPath $callsPath -Raw | ConvertFrom-Json); Installer=$installer; Launch=$launch }
    }

    # --- REGION: Invoke-WingetOutcomeFixture
    function Invoke-WingetOutcomeFixture {
        <# Executes the shared native gate and a shipped package phase with isolated commands. #>
        param([string]$Package, [long]$Code = 0, [string]$Mode = 'healthy', [string]$Workflow = 'code')
        $source = Get-Content (Join-Path $script:RepoRoot "guest/windows.11/windows.11.$Workflow.ps1") -Raw
        $sourceAst = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $helperAst = $sourceAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GuestWingetInstall'
        }, $true)
        if ($null -eq $helperAst) { throw 'Shared winget outcome gate was not found' }
        $helper = $helperAst.Extent.Text
        $boundaries = @{
            'Git.Git' = @('Install Git', 'Install Visual Studio Code')
            'Microsoft.VisualStudioCode' = @('Install Visual Studio Code', 'Ensure PowerShell is installed')
            'Microsoft.PowerShell' = @('Ensure PowerShell is installed', 'Install GitHub CLI')
            'GitHub.cli' = @('Install GitHub CLI', 'Refresh PATH')
        }
        if ($Workflow -eq 'code') {
            $start = $source.IndexOf('# --- REGION: ' + $boundaries[$Package][0])
            $end = $source.IndexOf('# --- REGION: ' + $boundaries[$Package][1], $start)
            if ($start -lt 0 -or $end -lt 0) { throw 'Package installer phase was not found' }
            $phase = $source.Substring($start, $end - $start)
        } else {
            # Exercise the shipped install and completion statements without host-specific setup.
            $install = $sourceAst.Find({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-GuestWingetInstall' -and
                $node.CommandElements[-1].Value -eq $Package
            }, $true)
            if ($null -eq $install) { throw "Package installer call was not found in $Workflow" }
            $completion = $sourceAst.Find({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.Extent.StartOffset -gt $install.Extent.EndOffset -and
                $node.GetCommandName() -eq 'Write-Output' -and
                $node.Extent.Text -match 'installation complete'
            }, $true)
            if ($null -eq $completion -and -not ($Workflow -eq 'update' -and $Package -eq 'Git.Git')) {
                throw "Package installer completion was not found in $Workflow"
            }
            $phase = $install.Extent.Text
            if ($null -ne $completion) { $phase += "`n" + $completion.Extent.Text }
        }
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $prefix = @'
$ErrorActionPreference = if ($env:YURUNA_WINGET_MODE -eq 'native-promotion') { 'Stop' } else { 'Continue' }
$PSNativeCommandUseErrorActionPreference = $true
$global:LASTEXITCODE = 73
$script:Calls = [ordered]@{ arguments=@(); priorExitCode=73; nativePromotion=$true; callerPromotion=$true }
function winget {
    $script:Calls.arguments=@($args)
    $script:Calls.priorExitCode=$global:LASTEXITCODE
    $script:Calls.nativePromotion=$PSNativeCommandUseErrorActionPreference
    Write-Output 'fixture native package output'
    if ($env:YURUNA_WINGET_MODE -eq 'launch-error') { throw [System.Management.Automation.CommandNotFoundException]::new('fixture winget could not launch') }
    if ($env:YURUNA_WINGET_MODE -eq 'dispatch-error') { Write-Error 'fixture winget dispatch failed'; return }
    if ($env:YURUNA_WINGET_MODE -eq 'no-outcome') { return }
    if ($env:YURUNA_WINGET_MODE -eq 'invalid-outcome') { $global:LASTEXITCODE = '0.5'; return }
    if ($env:YURUNA_WINGET_MODE -eq 'native-promotion') {
        & $env:YURUNA_WINGET_PWSH -NoProfile -NonInteractive -Command 'exit 7'
    }
    $global:LASTEXITCODE = [long]$env:YURUNA_WINGET_CODE
}
'@
        $suffix = @'
Write-Output 'would-install-next-package'
} finally {
    $script:Calls.callerPromotion=$PSNativeCommandUseErrorActionPreference
    $script:Calls | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:YURUNA_WINGET_RESULT
}
'@
        $entry = Join-Path $fixture 'fixture.ps1'
        $callsPath = Join-Path $fixture 'calls.json'
        Set-Content -LiteralPath $entry -Value ($prefix + "`n" + $helper + "`ntry {`n" + $phase + "`n" + $suffix) -Encoding utf8NoBOM
        # NO_COLOR: a child that believes it writes to a terminal colors its
        # error view, and the escape sequences sit before the gutter that the
        # strip below removes, then break the NUnit writer when they reach a
        # failure message.
        $result = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-File', $entry) -TimeoutSeconds 15 `
            -Environment @{ YURUNA_WINGET_MODE=$Mode; YURUNA_WINGET_CODE=[string]$Code; YURUNA_WINGET_RESULT=$callsPath; YURUNA_WINGET_PWSH=$script:Pwsh; NO_COLOR='1' }
        [pscustomobject]@{
            Process=$result
            Calls=(Get-Content -LiteralPath $callsPath -Raw | ConvertFrom-Json)
            ErrorText=($result.StdErr -replace '(?m)^\s*\|\s*', '' -replace '\s+', ' ')
        }
    }

    # --- REGION: Invoke-MacGitOutcomeFixture
    function Invoke-MacGitOutcomeFixture {
        <# Runs the shipped CLT/Git phase without invoking Apple tools or their GUI stubs. #>
        param([string]$Mode)
        $source = Get-Content (Join-Path $script:RepoRoot 'guest/macos.26/macos.26.update.sh') -Raw
        $start = $source.IndexOf('# --- REGION: Ensure Git is installed')
        $end = $source.IndexOf('# --- REGION: Resolve framework and project URLs', $start)
        if ($start -lt 0 -or $end -lt 0) { throw 'macOS CLT/Git phase was not found' }
        $phase = $source.Substring($start, $end - $start).Replace('/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress', '"$FIXTURE_ROOT/installondemand-marker"')
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $prefix = @'
set -euo pipefail
xcode-select() {
    [ "$*" = '-p' ] || return 90
    printf 'selection\n' >> "$FIXTURE_ROOT/calls"
    case "$FIXTURE_MODE" in selected|git-failure) printf '/fixture/CommandLineTools\n'; return 0 ;; esac
    if [ -f "$FIXTURE_ROOT/selected" ]; then printf '/fixture/CommandLineTools\n'; return 0; fi
    return 2
}
softwareupdate() {
    printf 'softwareupdate %s\n' "$*" >> "$FIXTURE_ROOT/calls"
    if [ "$1" = '-l' ]; then
        case "$FIXTURE_MODE" in no-label) return 0 ;; list-failure) return 1 ;; esac
        printf '* Label: Command Line Tools for Xcode-26.0\n'
        return 0
    fi
    [ "$*" = '-i Command Line Tools for Xcode-26.0 --verbose --agree-to-license' ] || return 91
    case "$FIXTURE_MODE" in
        install-success|install-error-usable) touch "$FIXTURE_ROOT/selected" ;;
    esac
    case "$FIXTURE_MODE" in install-error|install-error-usable) return 1 ;; esac
    return 0
}
sudo() {
    case "$1" in touch|rm|softwareupdate) "$@" ;; *) return 92 ;; esac
}
git() {
    [ "$*" = '--version' ] || return 93
    printf 'git-version\n' >> "$FIXTURE_ROOT/calls"
    [ "$FIXTURE_MODE" != git-failure ] || return 3
    printf 'git version fixture\n'
}
'@
        $entry = Join-Path $fixture 'fixture.sh'
        Set-Content -LiteralPath $entry -Value ($prefix + "`n" + $phase + "`nprintf 'would-resolve-repositories\n'`n") -Encoding utf8NoBOM
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Command bash -ErrorAction Stop).Source -ArgumentList @($entry) -TimeoutSeconds 15 `
            -Environment @{ FIXTURE_ROOT=$fixture; FIXTURE_MODE=$Mode }
        [pscustomobject]@{ Process=$result; Calls=(Get-Content -LiteralPath (Join-Path $fixture 'calls') -Raw); Marker=(Join-Path $fixture 'installondemand-marker') }
    }
}

Describe 'Windows guest JDK installer completion follows its native outcome' {
    It 'stops before release discovery for native query <Mode> code <Native>' -ForEach @(
        @{ Mode='healthy'; Native=99; Message='Unsupported native processor architecture' }
        @{ Mode='healthy'; Native=0; Message='Unsupported native processor architecture' }
        @{ Mode='healthy'; Native=5; Message='Unsupported native processor architecture' }
        @{ Mode='missing-architecture'; Native=9; Message='Unsupported native processor architecture' }
        @{ Mode='query-error'; Native=9; Message='native query failed' }
        @{ Mode='empty-query'; Native=9; Message='Cannot determine the native processor architecture' }
    ) {
        $result = Invoke-JdkOutcomeFixture -Mode $Mode -Native $Native
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match $Message
        $result.Calls.api | Should -Be 0
        $result.Calls.downloads | Should -Be 0
        $result.Calls.installs | Should -Be 0
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
        Get-Content -LiteralPath $result.Installer | Should -BeExactly 'stale installer'
    }

    It 'accepts documented MSI success <Code> for native processor <Native>' -ForEach @(
        @{ Code=0; Native=9; Arch='x64' }, @{ Code=0; Native=12; Arch='aarch64' }
        @{ Code=1641; Native=9; Arch='x64' }, @{ Code=1641; Native=12; Arch='aarch64' }
        @{ Code=3010; Native=9; Arch='x64' }, @{ Code=3010; Native=12; Arch='aarch64' }
    ) {
        $result = Invoke-JdkOutcomeFixture -Code $Code -Native $Native
        $result.Process.ExitCode | Should -Be 0
        $result.Process.StdOut | Should -Match '<<< JDK installation complete\.'
        $result.Process.StdOut | Should -Match 'would-install-next-package'
        $result.Calls.uri | Should -BeExactly "https://api.adoptium.net/v3/installer/latest/25/ga/windows/$Arch/jdk/hotspot/normal/eclipse"
        $result.Calls.arguments | Should -BeExactly "/i `"$($result.Installer)`" /qn /norestart ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome"
        $result.Calls.wait | Should -BeTrue
        $result.Calls.passThru | Should -BeTrue
        $result.Calls.downloadErrorAction | Should -BeExactly 'Stop'
        $result.Calls.installErrorAction | Should -BeExactly 'Stop'
        if ($Code -ne 0) { $result.Process.StdOut | Should -Match "requires a restart.*$Code" }
        Test-Path -LiteralPath $result.Installer | Should -BeFalse
    }

    It 'rejects MSI failure <Code> before reporting completion' -ForEach @(
        @{ Code=1 }, @{ Code=1603 }, @{ Code=1618 }, @{ Code=1638 }
    ) {
        $result = Invoke-JdkOutcomeFixture -Code $Code
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match "msiexec exit code $Code"
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
        $result.Calls.installs | Should -Be 1
        Test-Path -LiteralPath $result.Installer | Should -BeFalse
    }

    It 'stops and cleans the temporary installer on <Mode>' -ForEach @(
        @{ Mode='download-error'; Installs=0; Message='transfer failed' }
        @{ Mode='missing-download'; Installs=0; Message='nonempty installer' }
        @{ Mode='empty-download'; Installs=0; Message='nonempty installer' }
        @{ Mode='launch-error'; Installs=1; Message='could not start' }
        @{ Mode='null-process'; Installs=1; Message='no process outcome' }
        @{ Mode='missing-exit-code'; Installs=1; Message='no process outcome' }
    ) {
        $result = Invoke-JdkOutcomeFixture -Mode $Mode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match $Message
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
        $result.Calls.installs | Should -Be $Installs
        Test-Path -LiteralPath $result.Installer | Should -BeFalse
    }

    It 'preserves an unexpected installer directory and fails before transfer' {
        $result = Invoke-JdkOutcomeFixture -Mode directory
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match 'Expected a JDK installer file'
        $result.Calls.downloads | Should -Be 0
        $result.Calls.installs | Should -Be 0
        Get-Content -LiteralPath (Join-Path $result.Installer 'keep.txt') | Should -BeExactly 'preserve unexpected directory'
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
    }

    It 'stops before transfer when LTS discovery fails' {
        $result = Invoke-JdkOutcomeFixture -Mode api-error
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match 'LTS discovery failed'
        $result.Calls.downloads | Should -Be 0
        $result.Calls.installs | Should -Be 0
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
    }
}

Describe 'Windows guest SDK completion follows the downloaded installer outcome' {
    It 'accepts <Mode> independently of a stale caller exit code' -ForEach @(
        @{ Mode='healthy' }, @{ Mode='explicit-success' }
    ) {
        $result = Invoke-DotnetOutcomeFixture -Mode $Mode
        $result.Process.ExitCode | Should -Be 0
        $result.Process.StdOut | Should -Match 'would-register-machine-environment'
        $result.Process.StdOut | Should -Match '<<< \.NET SDK installation complete\.'
        $result.Calls.uri | Should -BeExactly 'https://dot.net/v1/dotnet-install.ps1'
        $result.Calls.downloadErrorAction | Should -BeExactly 'Stop'
        $result.Launch.Channel | Should -BeExactly 'LTS'
        $result.Launch.PriorExitCode | Should -Be 0
        Test-Path -LiteralPath $result.Installer | Should -BeFalse
    }

    It 'stops before environment registration after installer <Mode>' -ForEach @(
        @{ Mode='exit-error'; Message='installer exit code 17' }
        @{ Mode='launch-error'; Message='SDK installer threw' }
        @{ Mode='command-error'; Message='SDK installer command failed' }
    ) {
        $result = Invoke-DotnetOutcomeFixture -Mode $Mode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match $Message
        $result.Launch | Should -Not -BeNullOrEmpty
        $result.Process.StdOut | Should -Not -Match 'would-register-machine-environment|installation complete'
        Test-Path -LiteralPath $result.Installer | Should -BeFalse
    }

    It 'rejects a <Mode> before invoking the downloaded SDK script' -ForEach @(
        @{ Mode='download-error'; Message='SDK transfer failed' }
        @{ Mode='missing-download'; Message='nonempty installer' }
        @{ Mode='empty-download'; Message='nonempty installer' }
    ) {
        $result = Invoke-DotnetOutcomeFixture -Mode $Mode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match $Message
        $result.Launch | Should -BeNullOrEmpty
        $result.Process.StdOut | Should -Not -Match 'would-register-machine-environment|installation complete'
        Test-Path -LiteralPath $result.Installer | Should -BeFalse
    }

    It 'preserves an unexpected SDK installer directory without attempting a transfer' {
        $result = Invoke-DotnetOutcomeFixture -Mode directory
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match 'Expected a \.NET installer file'
        $result.Calls.downloads | Should -Be 0
        $result.Launch | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $result.Installer 'keep.txt') | Should -BeExactly 'preserve unexpected directory'
        $result.Process.StdOut | Should -Not -Match 'would-register-machine-environment|installation complete'
    }

    It 'fails closed when the downloaded SDK script disappears before invocation' {
        $result = Invoke-DotnetOutcomeFixture -Mode missing-launch
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match 'not recognized'
        $result.Launch | Should -BeNullOrEmpty
        $result.Process.StdOut | Should -Not -Match 'would-register-machine-environment|installation complete'
        Test-Path -LiteralPath $result.Installer | Should -BeFalse
    }
}

Describe 'Windows prerequisite winget phases share documented install outcomes' -ForEach @(
    @{ Package='Git.Git' }, @{ Package='Microsoft.VisualStudioCode' }, @{ Package='Microsoft.PowerShell' }, @{ Package='GitHub.cli' }
) {
    It 'accepts native status <Code> for <Package>' -ForEach @(
        @{ Code=0 }, @{ Code=-1978335189 }, @{ Code=-1978335135 }, @{ Code=2316632107L }, @{ Code=2316632161L }
    ) {
        $result = Invoke-WingetOutcomeFixture -Package $Package -Code $Code
        $result.Process.ExitCode | Should -Be 0
        $result.Process.StdOut | Should -Match 'fixture native package output'
        $result.Process.StdOut | Should -Match 'installation complete'
        $result.Process.StdOut | Should -Match 'would-install-next-package'
        ($result.Calls.arguments -join '|') | Should -BeExactly "install|--id|$Package|--accept-source-agreements|--accept-package-agreements|--silent"
        $result.Calls.priorExitCode | Should -BeNullOrEmpty
        $result.Calls.nativePromotion | Should -BeFalse
        $result.Calls.callerPromotion | Should -BeTrue
    }

    It 'rejects native failure <Code> for <Package>' -ForEach @(
        @{ Code=1 }, @{ Code=1603 }, @{ Code=-1978334963 }, @{ Code=-1978334962 }
    ) {
        $result = Invoke-WingetOutcomeFixture -Package $Package -Code $Code
        $result.Process.ExitCode | Should -Not -Be 0
        $result.ErrorText | Should -Match "winget exit code $Code"
        $result.ErrorText | Should -Match ([regex]::Escape($Package))
        $result.Process.StdOut | Should -Match 'fixture native package output'
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
    }

    It 'rejects a <Mode> for <Package> despite a stale caller exit code' -ForEach @(
        @{ Mode='launch-error' }, @{ Mode='dispatch-error' }
    ) {
        $result = Invoke-WingetOutcomeFixture -Package $Package -Mode $Mode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match 'fixture winget could not launch|fixture winget dispatch failed'
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
        $result.Calls.priorExitCode | Should -BeNullOrEmpty
        $result.Calls.callerPromotion | Should -BeTrue
    }

    It 'classifies an already-installed outcome for <Package> with ambient native error promotion enabled' {
        $result = Invoke-WingetOutcomeFixture -Package $Package -Code -1978335189 -Mode native-promotion
        $result.Process.ExitCode | Should -Be 0
        $result.Process.StdOut | Should -Match 'installation complete|would-install-next-package'
        $result.Calls.nativePromotion | Should -BeFalse
        $result.Calls.callerPromotion | Should -BeTrue
    }

    It 'rejects <Mode> from <Package> instead of inferring a native success' -ForEach @(
        @{ Mode='no-outcome' }, @{ Mode='invalid-outcome' }
    ) {
        $result = Invoke-WingetOutcomeFixture -Package $Package -Mode $Mode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.ErrorText | Should -Match 'without a valid native exit code'
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
        $result.Calls.priorExitCode | Should -BeNullOrEmpty
    }
}

Describe 'Windows guest prerequisite outcome parity' {
    It 'keeps the standalone native gate identical in <Workflow>' -ForEach @(
        @{ Workflow='k8s'; Packages=11 }, @{ Workflow='update'; Packages=2 }
    ) {
        $definitions = foreach ($entry in 'code', $Workflow) {
            $path = Join-Path $script:RepoRoot "guest/windows.11/windows.11.$entry.ps1"
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $helper = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GuestWingetInstall'
            }, $true)
            $helper.Extent.Text
        }
        $definitions[1] | Should -BeExactly $definitions[0]
        $calls = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-GuestWingetInstall'
        }, $true))
        $calls.Count | Should -Be $Packages
        $rawCalls = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'winget' -and
            $node.CommandElements[1].Value -eq 'install'
        }, $true))
        $rawCalls.Count | Should -Be 1 -Because 'the helper owns every native prerequisite install'
        $rawCalls[0].Extent.StartOffset | Should -BeGreaterThan $helper.Extent.StartOffset
        $rawCalls[0].Extent.EndOffset | Should -BeLessThan $helper.Extent.EndOffset
    }
}

Describe 'Windows <Workflow> prerequisite <Package> follows the shared native outcome' -ForEach @(
    @{ Workflow='k8s'; Package='Git.Git' },
    @{ Workflow='k8s'; Package='Microsoft.AzureCLI' },
    @{ Workflow='k8s'; Package='Amazon.AWSCLI' },
    @{ Workflow='k8s'; Package='Google.CloudSDK' },
    @{ Workflow='k8s'; Package='Docker.DockerDesktop' },
    @{ Workflow='k8s'; Package='Kubernetes.kubectl' },
    @{ Workflow='k8s'; Package='Helm.Helm' },
    @{ Workflow='k8s'; Package='OpenTofu.Tofu' },
    @{ Workflow='k8s'; Package='Graphviz.Graphviz' },
    @{ Workflow='k8s'; Package='GitHub.cli' },
    @{ Workflow='k8s'; Package='FiloSottile.mkcert' },
    @{ Workflow='update'; Package='Microsoft.PowerShell' },
    @{ Workflow='update'; Package='Git.Git' }
) {
    It 'accepts the documented already-installed outcome' {
        $result = Invoke-WingetOutcomeFixture -Workflow $Workflow -Package $Package -Code -1978335189
        $result.Process.ExitCode | Should -Be 0
        if ($Workflow -ne 'update' -or $Package -ne 'Git.Git') {
            $result.Process.StdOut | Should -Match 'installation complete'
        }
        $result.Process.StdOut | Should -Match 'would-install-next-package'
        ($result.Calls.arguments -join '|') | Should -BeExactly "install|--id|$Package|--accept-source-agreements|--accept-package-agreements|--silent"
    }

    It 'stops before completion and the next prerequisite on an installer failure' {
        $result = Invoke-WingetOutcomeFixture -Workflow $Workflow -Package $Package -Code 1603
        $result.Process.ExitCode | Should -Not -Be 0
        $result.ErrorText | Should -Match 'winget exit code 1603'
        $result.ErrorText | Should -Match ([regex]::Escape($Package))
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
    }

    It 'rejects an unavailable native outcome despite a stale caller status' {
        $result = Invoke-WingetOutcomeFixture -Workflow $Workflow -Package $Package -Mode no-outcome
        $result.Process.ExitCode | Should -Not -Be 0
        $result.ErrorText | Should -Match 'without a valid native exit code'
        $result.Calls.priorExitCode | Should -BeNullOrEmpty
        $result.Process.StdOut | Should -Not -Match 'installation complete|would-install-next-package'
    }
}

Describe 'macOS guest Git preparation proves selected noninteractive tools' -Skip:(-not $script:CanRunBash) {
    It 'continues when tools are usable after <Mode>' -ForEach @(
        @{ Mode='selected'; Updates=0 }, @{ Mode='install-success'; Updates=1 }, @{ Mode='install-error-usable'; Updates=1 }
    ) {
        $result = Invoke-MacGitOutcomeFixture -Mode $Mode
        $result.Process.ExitCode | Should -Be 0
        $result.Process.StdOut | Should -Match 'git version fixture'
        $result.Process.StdOut | Should -Match 'would-resolve-repositories'
        ([regex]::Matches($result.Calls, '(?m)^selection$')).Count | Should -Be 2
        ([regex]::Matches($result.Calls, '(?m)^softwareupdate -i ')).Count | Should -Be $Updates
        ([regex]::Matches($result.Calls, '(?m)^git-version$')).Count | Should -Be 1
        Test-Path -LiteralPath $result.Marker | Should -BeFalse
    }

    It 'fails without invoking Git when selection is absent after <Mode>' -ForEach @(
        @{ Mode='no-label' }, @{ Mode='list-failure' }, @{ Mode='install-error' }, @{ Mode='install-no-selection' }
    ) {
        $result = Invoke-MacGitOutcomeFixture -Mode $Mode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match 'Git cannot run noninteractively'
        $result.Process.StdOut | Should -Not -Match 'would-resolve-repositories'
        $result.Calls | Should -Not -Match 'git-version'
        ([regex]::Matches($result.Calls, '(?m)^selection$')).Count | Should -Be 2
        Test-Path -LiteralPath $result.Marker | Should -BeFalse
    }

    It 'fails when selected Git cannot execute' {
        $result = Invoke-MacGitOutcomeFixture -Mode git-failure
        $result.Process.ExitCode | Should -Be 3
        $result.Calls | Should -Match 'git-version'
        $result.Calls | Should -Not -Match 'softwareupdate'
        $result.Process.StdOut | Should -Not -Match 'would-resolve-repositories'
    }
}

Describe 'Amazon Linux PostgreSQL preserves cluster state on retries' -Skip:(-not $script:CanRunBash) {
    BeforeAll {
        # --- REGION: Invoke-PostgresClusterFixture
        function Invoke-PostgresClusterFixture {
            <# Runs the shipped RPM and cluster phases against private data with service commands stubbed. #>
            param([string]$Mode)
            $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $data = Join-Path $fixture 'data'
            $null = New-Item -ItemType Directory -Path $fixture
            if ($Mode -ne 'absent') { $null = New-Item -ItemType Directory -Path $data }
            switch ($Mode) {
                'initialized' {
                    Set-Content -LiteralPath (Join-Path $data 'PG_VERSION') -Value '17'
                    Set-Content -LiteralPath (Join-Path $data 'keep') -Value 'existing database'
                }
                'wrong-major' { Set-Content -LiteralPath (Join-Path $data 'PG_VERSION') -Value '16' }
                'partial' { Set-Content -LiteralPath (Join-Path $data 'keep') -Value 'partial database' }
                'linked-partial' {
                    Remove-Item -LiteralPath $data
                    $linkedData = Join-Path $fixture 'linked-data'
                    $null = New-Item -ItemType Directory -Path $linkedData
                    Set-Content -LiteralPath (Join-Path $linkedData 'keep') -Value 'partial database'
                    $null = New-Item -ItemType SymbolicLink -Path $data -Target $linkedData
                }
                'empty-version' { [IO.File]::WriteAllText((Join-Path $data 'PG_VERSION'), '') }
                'directory-version' { $null = New-Item -ItemType Directory -Path (Join-Path $data 'PG_VERSION') }
                'read-failure' { Set-Content -LiteralPath (Join-Path $data 'PG_VERSION') -Value '17' }
            }
            $source = Get-Content (Join-Path $script:RepoRoot 'guest/amazon.linux.2023/amazon.linux.2023.postgresql.sh') -Raw
            $start = $source.IndexOf('# --- REGION: Install PostgreSQL')
            $end = $source.IndexOf('# --- REGION: Installation summary', $start)
            if ($start -lt 0 -or $end -lt 0) { throw 'PostgreSQL installation phases were not found' }
            $source = $source.Substring($start, $end - $start).Replace('/var/lib/pgsql/data', '"$YURUNA_POSTGRES_DATA"')
            $prefix = @'
set -euo pipefail
: > "$YURUNA_POSTGRES_CALLS"
dnf_retry() {
    printf 'packages\n' >> "$YURUNA_POSTGRES_CALLS"
    [ "$YURUNA_POSTGRES_MODE" != package-failure ]
}
sudo() {
    case "$1" in
        test) command "$@" ;;
        cat)
            [ "$YURUNA_POSTGRES_MODE" != read-failure ] || return 42
            command "$@"
            ;;
        find)
            [ "$YURUNA_POSTGRES_MODE" != find-failure ] || return 41
            command "$@"
            ;;
        /usr/bin/postgresql-setup)
            [ "$#" = 2 ] && [ "$2" = --initdb ] || return 90
            printf 'initialize\n' >> "$YURUNA_POSTGRES_CALLS"
            [ "$YURUNA_POSTGRES_MODE" != init-failure ] || return 37
            mkdir -p "$YURUNA_POSTGRES_DATA"
            printf '17\n' > "$YURUNA_POSTGRES_DATA/PG_VERSION"
            ;;
        systemctl) printf '%s\n' "$*" >> "$YURUNA_POSTGRES_CALLS" ;;
        *) printf 'Unexpected sudo command: %s\n' "$*" >&2; return 91 ;;
    esac
}
'@
            $entry = Join-Path $fixture 'fixture.sh'
            $calls = Join-Path $fixture 'calls.txt'
            Set-Content -LiteralPath $entry -Value ($prefix + "`n" + $source + "`necho would-report-summary") -Encoding utf8NoBOM
            $process = Invoke-BoundedNativeCommand -FilePath (Get-Command bash).Source -ArgumentList @($entry) -TimeoutSeconds 10 `
                -Environment @{ YURUNA_POSTGRES_MODE=$Mode; YURUNA_POSTGRES_DATA=$data; YURUNA_POSTGRES_CALLS=$calls }
            [pscustomobject]@{ Process=$process; Calls=@(Get-Content -LiteralPath $calls); Data=$data }
        }
    }

    It 'starts the existing major or initializes a fresh cluster for <Mode>' -ForEach @(
        @{ Mode='absent'; Initializes=1 }, @{ Mode='empty'; Initializes=1 }, @{ Mode='initialized'; Initializes=0 }
    ) {
        $result = Invoke-PostgresClusterFixture -Mode $Mode
        $result.Process.ExitCode | Should -Be 0 -Because $result.Process.StdErr
        @($result.Calls | Where-Object { $_ -eq 'initialize' }).Count | Should -Be $Initializes
        ($result.Calls | Select-Object -Last 2) -join '|' | Should -BeExactly 'systemctl enable postgresql|systemctl start postgresql'
        $result.Calls | Should -Not -Contain 'systemctl stop postgresql'
        Get-Content -LiteralPath (Join-Path $result.Data 'PG_VERSION') | Should -BeExactly '17'
        if ($Mode -eq 'initialized') {
            Get-Content -LiteralPath (Join-Path $result.Data 'keep') | Should -BeExactly 'existing database'
        }
        $result.Process.StdOut | Should -Match 'would-report-summary'
    }

    It 'refuses to initialize or start a cluster with <Mode>' -ForEach @(
        @{ Mode='wrong-major' }, @{ Mode='partial' }, @{ Mode='linked-partial' }, @{ Mode='empty-version' }, @{ Mode='directory-version' },
        @{ Mode='package-failure' }, @{ Mode='read-failure' }, @{ Mode='find-failure' }
    ) {
        $result = Invoke-PostgresClusterFixture -Mode $Mode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Calls | Should -Not -Contain 'initialize'
        @($result.Calls | Where-Object { $_ -like 'systemctl *' }) | Should -BeNullOrEmpty
        $result.Process.StdOut | Should -Not -Match 'would-report-summary'
        if ($Mode -eq 'wrong-major') {
            Get-Content -LiteralPath (Join-Path $result.Data 'PG_VERSION') | Should -BeExactly '16'
            $result.Process.StdErr | Should -Match 'Migrate it explicitly'
        }
        if ($Mode -in @('partial', 'linked-partial')) {
            Get-Content -LiteralPath (Join-Path $result.Data 'keep') | Should -BeExactly 'partial database'
            $result.Process.StdErr | Should -Match 'refusing to initialize'
        }
    }

    It 'does not enable or start PostgreSQL after initialization fails' {
        $result = Invoke-PostgresClusterFixture -Mode init-failure
        $result.Process.ExitCode | Should -Be 37
        $result.Calls | Should -Contain 'initialize'
        @($result.Calls | Where-Object { $_ -like 'systemctl *' }) | Should -BeNullOrEmpty
        $result.Process.StdOut | Should -Not -Match 'would-report-summary'
        Test-Path -LiteralPath (Join-Path $result.Data 'PG_VERSION') | Should -BeFalse
    }
}
