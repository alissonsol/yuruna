<#PSScriptInfo
.VERSION 2026.09.27
.GUID 429aa498-3e96-4845-88b0-cbeb890aeb90
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test utmctl bounded native macos pester
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
    utmctl calls outside the macOS driver are bounded: the orphan sweep, the
    SSH address fallback and the system diagnostic.
.DESCRIPTION
    utmctl is an Apple Events client with no timeout of its own, so a UTM that
    stopped answering holds a bare call forever. Each of these call sites goes
    through the driver's Invoke-UtmctlProbe / Invoke-UtmctlLifecycle when the
    driver is loaded and through Invoke-BoundedNativeCommand otherwise, and
    treats a call that did not finish as no answer -- never as an empty or
    negative one.

    The cases run on any host: a stand-in utmctl (and plutil) on a private
    PATH answers from files in a private directory, can be told to hang, and
    logs every call. No real UTM, VM or bundle is touched.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    $script:OrphanScript = Join-Path $script:RepoRoot 'host/macos.utm/Remove-OrphanedVMFiles.ps1'
    $script:SshModule = Join-Path $here 'Test.Ssh.psm1'
    $script:DiagScript = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'
    $script:Temp = New-YurunaTestTempDir -Prefix 'utmctl-outside'
    $script:Bin = Join-Path $script:Temp 'bin'
    $script:EmptyBin = Join-Path $script:Temp 'empty-bin'
    $null = New-Item -ItemType Directory -Path $script:Bin, $script:EmptyBin -Force

    $utmctl = @'
#!/bin/bash
d="$UTMCTL_FAKE_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
verb="$1"; target="$2"
if [ -f "$d/sleep-$verb" ]; then sleep 30; fi
case "$verb" in
  list)
    [ -f "$d/list.out" ] && cat "$d/list.out"
    [ -f "$d/list.err" ] && cat "$d/list.err" >&2
    exit "$(cat "$d/list.exit" 2>/dev/null || echo 0)" ;;
  status)
    if [ -f "$d/deleted-$target" ] && [ -f "$d/after-delete-status-$target" ]; then exit "$(cat "$d/after-delete-status-$target")"; fi
    exit "$(cat "$d/status-$target" 2>/dev/null || echo 1)" ;;
  delete)
    touch "$d/deleted-$target"
    exit "$(cat "$d/delete-$target" 2>/dev/null || echo 0)" ;;
  ip-address)
    if [ -f "$d/ip-$target" ]; then cat "$d/ip-$target"; exit 0; fi
    echo "no guest agent" >&2
    exit 1 ;;
esac
exit 2
'@
    $plutil = @'
#!/bin/bash
for last in "$@"; do :; done
cat "$last"
'@
    foreach ($tool in @(@{ Name = 'utmctl'; Body = $utmctl }, @{ Name = 'plutil'; Body = $plutil })) {
        $path = Join-Path $script:Bin $tool.Name
        [System.IO.File]::WriteAllText($path, ($tool.Body -replace "`r`n", "`n"))
        if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($path, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    }
    $script:SavedPath = $env:PATH
    $script:SavedFakeDir = $env:UTMCTL_FAKE_DIR

    function New-FakeState {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a throwaway stand-in state directory.')]
        [CmdletBinding()]
        param([hashtable]$File = @{})
        $dir = Join-Path $script:Temp ('state-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        $null = New-Item -ItemType Directory -Path $dir -Force
        foreach ($name in $File.Keys) { [System.IO.File]::WriteAllText((Join-Path $dir $name), [string]$File[$name]) }
        $env:UTMCTL_FAKE_DIR = $dir
        $dir
    }
    function Get-FakeCall {
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$StateDir)
        $log = Join-Path $StateDir 'calls.log'
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
    }
    function Import-ScriptFunction {
        [CmdletBinding()]
        param([string]$Path, [string[]]$Name)
        foreach ($n in $Name) {
            $definition = Get-YurunaTestFunctionAst -Path $Path -Name $n
            if (-not $definition) { throw "Test.UtmctlOutsideDriver.Tests.ps1: '$n' not found in $Path." }
            $definition.Extent.Text
        }
    }
}

AfterAll {
    $env:PATH = $script:SavedPath
    if ($null -eq $script:SavedFakeDir) { Remove-Item -LiteralPath 'Env:UTMCTL_FAKE_DIR' -ErrorAction SilentlyContinue } else { $env:UTMCTL_FAKE_DIR = $script:SavedFakeDir }
    foreach ($stub in 'Invoke-UtmctlProbe', 'Invoke-UtmctlLifecycle') { Remove-Item -LiteralPath "Function:\$stub" -ErrorAction SilentlyContinue }
    Remove-YurunaTestTempDir $script:Temp
}

Describe 'No bare utmctl invocation outside the driver' {
    It 'runs utmctl in <File> only through a bounded runner' -TestCases @(
        @{ File = 'host/macos.utm/Remove-OrphanedVMFiles.ps1' }
        @{ File = 'test/modules/Test.Ssh.psm1' }
        @{ File = 'automation/Get-SystemDiagnostic.ps1' }
    ) {
        param($File)
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot $File)
        $bare = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'utmctl' }, $true))
        $bare.Count | Should -Be 0 -Because "$File must not start utmctl without a wall-clock cap"
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot $File) -Raw
        $text | Should -Match 'Invoke-UtmctlProbe'
        $text | Should -Match 'Invoke-BoundedNativeCommand'
    }
}

Describe 'Remove-OrphanedVMFiles.ps1 -- the bounded registration helpers' {
    BeforeAll {
        foreach ($definition in (Import-ScriptFunction -Path $script:OrphanScript -Name 'Invoke-OrphanSweepUtmctl', 'Get-OrphanSweepRegistration')) {
            . ([scriptblock]::Create($definition))
        }
        $script:Utmctl = Join-Path $script:Bin 'utmctl'
    }
    AfterEach { foreach ($stub in 'Invoke-UtmctlProbe', 'Invoke-UtmctlLifecycle') { Remove-Item -LiteralPath "Function:\$stub" -ErrorAction SilentlyContinue } }

    It 'runs the resolved executable through the bounded runner when the driver is not loaded' {
        $state = New-FakeState -File @{ 'list.out' = "UUID Status Name`nAAAA started one`n"; 'status-AAAA' = '0' }
        $listing = Invoke-OrphanSweepUtmctl -Verb list -UtmctlPath $script:Utmctl
        $listing.Complete | Should -BeTrue
        $listing.ExitCode | Should -Be 0
        $listing.Line | Should -Contain 'AAAA started one'
        Get-OrphanSweepRegistration -Target 'AAAA' -UtmctlPath $script:Utmctl | Should -Be 'registered'
        Get-OrphanSweepRegistration -Target 'BBBB' -UtmctlPath $script:Utmctl | Should -Be 'absent'
        (Get-FakeCall -StateDir $state) | Should -Be @('list', 'status AAAA', 'status BBBB')
    }

    It 'reads an unanswered status probe as unknown, within its cap' {
        $null = New-FakeState -File @{ 'sleep-status' = ''; 'status-CCCC' = '1' }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Get-OrphanSweepRegistration -Target 'CCCC' -UtmctlPath $script:Utmctl -TimeoutSeconds 1 | Should -Be 'unknown'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
    }

    It 'reports an unanswered listing as incomplete rather than empty' {
        $null = New-FakeState -File @{ 'sleep-list' = ''; 'list.out' = "UUID Status Name`n" }
        $listing = Invoke-OrphanSweepUtmctl -Verb list -UtmctlPath $script:Utmctl -TimeoutSeconds 1
        $listing.Complete | Should -BeFalse
        $listing.TimedOut | Should -BeTrue
    }

    It 'uses the driver wrappers when the driver is loaded' {
        $script:DriverCalls = [System.Collections.Generic.List[string]]::new()
        function global:Invoke-UtmctlProbe {
            [CmdletBinding()] [OutputType([hashtable])] param([string[]]$Arguments, [int]$TimeoutSeconds, [string]$UtmctlPath, $Deadline, [switch]$Quiet)
            $null = $Deadline
            $script:DriverCalls.Add("probe $($Arguments -join ' ') path=$UtmctlPath quiet=$([bool]$Quiet) cap=$TimeoutSeconds")
            @{ ExitCode = 0; StdOut = 'listed'; StdErr = ''; TimedOut = $false; Started = $true; DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false }
        }
        function global:Invoke-UtmctlLifecycle {
            [CmdletBinding()] [OutputType([hashtable])] param([string]$Verb, [string]$VMName, [switch]$Kill, $Deadline, [int]$TimeoutSeconds, [switch]$Quiet)
            $null = $Kill, $Deadline
            $script:DriverCalls.Add("lifecycle $Verb $VMName quiet=$([bool]$Quiet) cap=$TimeoutSeconds")
            @{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $true; Started = $true; DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; OutcomeKnown = $false }
        }
        $state = New-FakeState
        (Invoke-OrphanSweepUtmctl -Verb list -UtmctlPath '/fake/utmctl').Line | Should -Be @('listed')
        Get-OrphanSweepRegistration -Target 'DDDD' -UtmctlPath '/fake/utmctl' | Should -Be 'registered'
        $deletion = Invoke-OrphanSweepUtmctl -Verb delete -Target 'DDDD' -UtmctlPath '/fake/utmctl'
        $deletion.Complete | Should -BeFalse -Because 'a timed-out delete has an unknown effect'
        $script:DriverCalls | Should -Be @(
            'probe list path=/fake/utmctl quiet=True cap=20'
            'probe status DDDD path=/fake/utmctl quiet=True cap=20'
            'lifecycle delete DDDD quiet=True cap=120')
        Get-FakeCall -StateDir $state | Should -BeNullOrEmpty -Because 'the stand-in utmctl was never run directly'
    }
}

Describe 'Remove-OrphanedVMFiles.ps1 -- the sweep end to end against a stand-in utmctl' {
    BeforeAll {
        function Invoke-OrphanSweep {
            [CmdletBinding()]
            param([hashtable]$File, [string[]]$Bundle)
            $homeDir = Join-Path $script:Temp ('home-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
            $scan = Join-Path $homeDir 'yuruna/guest.nosync'
            $null = New-Item -ItemType Directory -Path $scan -Force
            foreach ($entry in $Bundle) {
                $name, $uuid = $entry -split '=', 2
                $bundleDir = Join-Path $scan "$name.utm"
                $null = New-Item -ItemType Directory -Path $bundleDir -Force
                [System.IO.File]::WriteAllText((Join-Path $bundleDir 'config.plist'), $uuid)
            }
            $state = New-FakeState -File $File
            $savedHome = $env:HOME
            try {
                $env:HOME = $homeDir
                $env:PATH = "$($script:Bin)$([System.IO.Path]::PathSeparator)$($script:SavedPath)"
                $pwsh = (Get-Process -Id $PID).Path
                $out = & $pwsh -NoLogo -NoProfile -NonInteractive -File $script:OrphanScript -Force 2>&1
                $code = $LASTEXITCODE
            } finally {
                $env:HOME = $savedHome
                $env:PATH = $script:SavedPath
            }
            [pscustomobject]@{
                ExitCode = $code
                Output   = (($out | ForEach-Object { "$_" }) -join "`n") -replace '\x1b\[[0-9;]*[A-Za-z]', ''
                Calls    = @(Get-FakeCall -StateDir $state)
                Left     = @(Get-ChildItem -LiteralPath $scan -Directory | ForEach-Object Name | Sort-Object)
            }
        }
        $script:UuidA = '11111111-1111-1111-1111-111111111111'
        $script:UuidB = '22222222-2222-2222-2222-222222222222'
        $script:UuidC = '33333333-3333-3333-3333-333333333333'
        $script:ListOut = "UUID                                 Status   Name`n$($script:UuidA) started  registered`n"
    }

    It 'keeps registered and stopped bundles and removes a deregistered orphan' {
        $r = Invoke-OrphanSweep -File @{ 'list.out' = $script:ListOut; "status-$($script:UuidB)" = '0' } `
            -Bundle "registered=$($script:UuidA)", "stopped=$($script:UuidB)", "orphan=$($script:UuidC)"
        $r.ExitCode | Should -Be 0
        $r.Left | Should -Be @('registered.utm', 'stopped.utm')
        # Bundles are visited in hash order, so the probes are compared as a
        # set; the delete must come before the probe that verifies it.
        $r.Calls[0] | Should -Be 'list'
        ($r.Calls | Sort-Object) | Should -Be (@('list', "status $($script:UuidB)", "status $($script:UuidC)", "delete $($script:UuidC)", "status $($script:UuidC)") | Sort-Object)
        $r.Calls[-1] | Should -Be "status $($script:UuidC)"
        $r.Calls[-2] | Should -Be "delete $($script:UuidC)"
    }

    It 'refuses to sweep when the listing fails' {
        $r = Invoke-OrphanSweep -File @{ 'list.out' = ''; 'list.exit' = '1' } -Bundle "orphan=$($script:UuidC)"
        $r.ExitCode | Should -Be 1
        $r.Left | Should -Be @('orphan.utm')
        @($r.Calls | Where-Object { $_ -like 'delete*' }).Count | Should -Be 0
    }

    It 'refuses to sweep when the listing reports an Apple Events failure with exit 0' {
        $r = Invoke-OrphanSweep -File @{ 'list.out' = "UUID Status Name`n"; 'list.err' = 'Error: The operation couldn''t be completed. (OSStatus error -1743.)' } -Bundle "orphan=$($script:UuidC)"
        $r.ExitCode | Should -Be 1
        $r.Left | Should -Be @('orphan.utm')
    }

    It 'keeps a bundle whose VM is still registered after the delete' {
        $r = Invoke-OrphanSweep -File @{ 'list.out' = $script:ListOut; "after-delete-status-$($script:UuidC)" = '0' } -Bundle "orphan=$($script:UuidC)"
        $r.Left | Should -Be @('orphan.utm')
        $r.Calls | Should -Contain "delete $($script:UuidC)"
    }
}

Describe 'Test.Ssh -- the utmctl ip-address fallback is bounded' {
    BeforeAll {
        Import-Module $script:SshModule -Force -Global -DisableNameChecking
        $script:AskUtmctl = { param([string]$VMName, [int]$TimeoutSeconds) & (Get-Module Test.Ssh) { param($n, $t) Get-GuestAddressFromUtmctl -VMName $n -TimeoutSeconds $t } $VMName $TimeoutSeconds }
    }
    BeforeEach { $env:PATH = "$($script:Bin)$([System.IO.Path]::PathSeparator)$($script:SavedPath)" }
    AfterEach {
        $env:PATH = $script:SavedPath
        Remove-Item -LiteralPath 'Function:\Invoke-UtmctlProbe' -ErrorAction SilentlyContinue
    }

    It 'returns the address the agent reports through the bounded runner' {
        $state = New-FakeState -File @{ 'ip-vm1' = "fe80::1`n192.168.64.7`n" }
        & $script:AskUtmctl 'vm1' 20 | Should -Be '192.168.64.7'
        Get-FakeCall -StateDir $state | Should -Be @('ip-address vm1')
    }
    It 'returns nothing for a non-zero exit' {
        $null = New-FakeState
        & $script:AskUtmctl 'vm2' 20 | Should -BeNullOrEmpty
    }
    It 'returns nothing, within its cap, when utmctl does not answer' {
        $null = New-FakeState -File @{ 'sleep-ip-address' = ''; 'ip-vm3' = '192.168.64.9' }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        & $script:AskUtmctl 'vm3' 1 | Should -BeNullOrEmpty
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
    }
    It 'returns nothing and runs nothing when no utmctl is on PATH' {
        $env:PATH = $script:EmptyBin
        $state = New-FakeState -File @{ 'ip-vm4' = '192.168.64.4' }
        & $script:AskUtmctl 'vm4' 20 | Should -BeNullOrEmpty
        Get-FakeCall -StateDir $state | Should -BeNullOrEmpty
    }
    It 'asks through the driver probe, quietly, when the driver is loaded' {
        $script:ProbeArgs = $null
        function global:Invoke-UtmctlProbe {
            [CmdletBinding()] [OutputType([hashtable])] param([string[]]$Arguments, [int]$TimeoutSeconds, [string]$UtmctlPath, $Deadline, [switch]$Quiet)
            $null = $TimeoutSeconds, $Deadline
            $script:ProbeArgs = "$($Arguments -join ' ')|$UtmctlPath|$([bool]$Quiet)"
            @{ ExitCode = 0; StdOut = "10.20.30.40`n"; StdErr = ''; TimedOut = $false; Started = $true; DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false }
        }
        $state = New-FakeState
        & $script:AskUtmctl 'vm5' 20 | Should -Be '10.20.30.40'
        $script:ProbeArgs | Should -Be "ip-address vm5|$(Join-Path $script:Bin 'utmctl')|True"
        Get-FakeCall -StateDir $state | Should -BeNullOrEmpty
    }
}

Describe 'Get-SystemDiagnostic.ps1 -- utmctl list is bounded' {
    BeforeAll {
        foreach ($definition in (Import-ScriptFunction -Path $script:DiagScript -Name 'Get-DiagnosticUtmctlListing')) {
            . ([scriptblock]::Create($definition))
        }
    }
    BeforeEach { $env:PATH = "$($script:Bin)$([System.IO.Path]::PathSeparator)$($script:SavedPath)" }
    AfterEach {
        $env:PATH = $script:SavedPath
        Remove-Item -LiteralPath 'Function:\Invoke-UtmctlProbe' -ErrorAction SilentlyContinue
    }

    It 'prints the standard output lines of a bounded listing' {
        $null = New-FakeState -File @{ 'list.out' = "UUID Status Name`nAAAA started one`n"; 'list.err' = 'noise on stderr' }
        $lines = @(Get-DiagnosticUtmctlListing)
        $lines | Should -Be @('UUID Status Name', 'AAAA started one')
    }
    It 'adds a note instead of hanging when utmctl does not answer' {
        Mock Format-YurunaOperatorMessage { "KEY:$Key" }
        $null = New-FakeState -File @{ 'sleep-list' = '' }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $lines = @(Get-DiagnosticUtmctlListing -TimeoutSeconds 1)
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
        $lines | Should -Contain 'KEY:automation.system_diagnostic_utmctl_list_incomplete'
    }
    It 'asks through the driver probe when the driver is loaded' {
        function global:Invoke-UtmctlProbe {
            [CmdletBinding()] [OutputType([hashtable])] param([string[]]$Arguments, [int]$TimeoutSeconds, [string]$UtmctlPath, $Deadline, [switch]$Quiet)
            $null = $Deadline, $Quiet, $TimeoutSeconds, $UtmctlPath
            @{ ExitCode = 0; StdOut = "from driver $($Arguments -join ' ')`n"; StdErr = ''; TimedOut = $false; Started = $true }
        }
        $state = New-FakeState
        @(Get-DiagnosticUtmctlListing) | Should -Be @('from driver list')
        Get-FakeCall -StateDir $state | Should -BeNullOrEmpty
    }
    It 'prints nothing when no utmctl is on PATH' {
        $env:PATH = $script:EmptyBin
        @(Get-DiagnosticUtmctlListing).Count | Should -Be 0
    }
    It 'keeps the partial listing and adds the note for any answer that is not complete (<Flag>)' -TestCases @(
        @{ Flag = 'DrainTimedOut' }, @{ Flag = 'OutputTruncated' }, @{ Flag = 'KillFailed' }, @{ Flag = 'NotStarted' }
    ) {
        param($Flag)
        Mock Format-YurunaOperatorMessage { "KEY:$Key" }
        $flag = $Flag
        $stub = {
            [CmdletBinding()] [OutputType([hashtable])] param([string[]]$Arguments, [int]$TimeoutSeconds, [string]$UtmctlPath, $Deadline, [switch]$Quiet)
            $null = $Arguments, $Deadline, $Quiet, $TimeoutSeconds, $UtmctlPath
            $result = @{ ExitCode = 0; StdOut = "UUID Status Name`nAAAA started one`n"; StdErr = ''; TimedOut = $false; Started = $true
                DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false }
            if ($flag -eq 'NotStarted') { $result.Started = $false; $result.StdOut = '' } else { $result[$flag] = $true }
            $result
        }.GetNewClosure()
        Set-Item -Path 'Function:global:Invoke-UtmctlProbe' -Value $stub
        $null = New-FakeState
        $lines = @(Get-DiagnosticUtmctlListing)
        $lines | Should -Contain 'KEY:automation.system_diagnostic_utmctl_list_incomplete'
        if ($Flag -ne 'NotStarted') { $lines | Should -Contain 'AAAA started one' }
    }
    It 'adds no note to a complete answer' {
        Mock Format-YurunaOperatorMessage { "KEY:$Key" }
        $null = New-FakeState -File @{ 'list.out' = "UUID Status Name`n" }
        @(Get-DiagnosticUtmctlListing) | Should -Not -Contain 'KEY:automation.system_diagnostic_utmctl_list_incomplete'
    }
}
