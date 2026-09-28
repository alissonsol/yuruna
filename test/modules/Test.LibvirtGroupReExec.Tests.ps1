<#PSScriptInfo
.VERSION 2026.09.27
.GUID 423d18da-7e97-4117-9ac0-6c6e5a592415
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host libvirt relaunch pester
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
    The libvirt group relaunch in Test.HostDetection: the side-effect-free
    decision a preview can report, the rendering of bound parameters into
    the relaunched command (and its refusal of values that cannot survive
    it), and a real round trip -- a child pwsh relaunched through a stand-in
    sg on a private PATH -- that proves the child is non-interactive, sees
    the relaunch marker, receives strings, numbers above the Int32 range,
    switches, booleans and string arrays intact, and hands its exit code
    back through the parent. On a real terminal the relaunched child must
    also know it cannot prompt, so its prompt sites take their non-prompt
    path instead of throwing at the first question.
#>

BeforeDiscovery {
    # The terminal case needs a pseudo-terminal, which util-linux script(1)
    # provides; its option syntax differs on macOS, so it runs on Linux only.
    $script:SkipTerminalCase = (-not $IsLinux) -or
        (-not (Get-Command -Name 'script' -CommandType Application -ErrorAction SilentlyContinue))
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostDetection.psm1') -Force -DisableNameChecking
    $script:ModulePath = Join-Path $here 'Test.HostDetection.psm1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = 'pwsh' }
    $script:User = if ($env:USER) { $env:USER } else { [Environment]::UserName }
    $script:HadRelaunch = Test-Path -LiteralPath Env:YURUNA_SG_RELAUNCH
    $script:SavedRelaunch = $env:YURUNA_SG_RELAUNCH

    function Get-FakeBoundedResult {
        param([int]$ExitCode = 0, [string]$StdOut = '', [switch]$TimedOut, [switch]$NotStarted,
            [switch]$DrainTimedOut, [switch]$OutputTruncated, [switch]$KillFailed)
        @{
            ExitCode = if ($TimedOut) { 124 } elseif ($NotStarted) { -1 } else { $ExitCode }
            StdOut = $StdOut; StdErr = ''; TimedOut = [bool]$TimedOut; Started = -not $NotStarted
            DrainTimedOut = [bool]$DrainTimedOut; KillFailed = [bool]$KillFailed; OutputTruncated = [bool]$OutputTruncated
            ElapsedMs = 1; DeadlineExhausted = $false; ProcessId = 1
        }
    }

    # Writes the stand-in id, getent and sg a relaunch needs into a private
    # PATH directory: the user is a libvirt member whose running group set
    # lacks the group, and sg records the group then runs its -c command in
    # bash.
    function New-FakeGroupTool {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes stand-in executables into a throwaway temp dir.')]
        param([string]$Directory)
        $bin = Join-Path $Directory 'bin'
        $null = [IO.Directory]::CreateDirectory($bin)
        $fakes = @{
            'id'     = "#!/usr/bin/env bash`nif [ `"`$1`" = '-nG' ]; then echo 'users kvm'; exit 0; fi`nexit 1`n"
            'getent' = "#!/usr/bin/env bash`nif [ `"`$1`" = 'group' ] && [ `"`$2`" = 'libvirt' ]; then echo `"libvirt:x:973:someone,`$USER`"; exit 0; fi`nexit 2`n"
            'sg'     = "#!/usr/bin/env bash`nprintf '%s\n' `"`$1`" > `"`$SG_TRACE`"`nshift`n[ `"`$1`" = '-c' ] || exit 97`nexec bash -c `"`$2`"`n"
        }
        foreach ($name in $fakes.Keys) {
            $path = Join-Path $bin $name
            [IO.File]::WriteAllText($path, $fakes[$name])
            [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        return $bin
    }

    function Restore-RelaunchMarker {
        if ($script:HadRelaunch) { $env:YURUNA_SG_RELAUNCH = $script:SavedRelaunch }
        else { Remove-Item -LiteralPath Env:YURUNA_SG_RELAUNCH -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-LibvirtGroupReExecNeeded -- a decision with no side effects' {
    BeforeEach { Remove-Item -LiteralPath Env:YURUNA_SG_RELAUNCH -ErrorAction SilentlyContinue }
    AfterEach { Restore-RelaunchMarker }

    It 'needs nothing, and probes nothing, off Ubuntu KVM' {
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { throw 'no probe expected' }
        foreach ($hostType in @('host.macos.utm', 'host.windows.hyper-v')) {
            $d = Test-LibvirtGroupReExecNeeded -HostType $hostType
            $d.Needed | Should -Be $false
            $d.Reason | Should -Be 'not-kvm'
        }
        Should -Invoke -ModuleName Test.HostDetection Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'needs nothing inside an existing relaunch' {
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { throw 'no probe expected' }
        $env:YURUNA_SG_RELAUNCH = '1'
        $d = Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm'
        $d.Reason | Should -Be 'already-relaunched'
    }

    It 'reports probe-failed, never a guess, when the group probe does not answer' {
        foreach ($idResult in @((Get-FakeBoundedResult -TimedOut), (Get-FakeBoundedResult -NotStarted), (Get-FakeBoundedResult -ExitCode 1))) {
            Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { $idResult }.GetNewClosure() -ParameterFilter { $FilePath -eq 'id' }
            $d = Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm'
            $d.Needed | Should -Be $false
            $d.Reason | Should -Be 'probe-failed'
        }
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { Get-FakeBoundedResult -StdOut 'users kvm' } -ParameterFilter { $FilePath -eq 'id' }
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { Get-FakeBoundedResult -TimedOut } -ParameterFilter { $FilePath -eq 'getent' }
        (Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm').Reason | Should -Be 'probe-failed'
    }

    It 'reports probe-failed for partial output, even with a clean exit code' {
        # A group list cut short could omit 'libvirt' and read as a definite
        # "not in the set"; only a complete answer is an answer.
        $partialId = @(
            (Get-FakeBoundedResult -StdOut 'users kvm' -OutputTruncated),
            (Get-FakeBoundedResult -StdOut 'users kvm' -DrainTimedOut),
            (Get-FakeBoundedResult -StdOut 'users kvm' -KillFailed)
        )
        foreach ($idResult in $partialId) {
            Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { $idResult }.GetNewClosure() -ParameterFilter { $FilePath -eq 'id' }
            (Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm').Reason | Should -Be 'probe-failed'
        }
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { Get-FakeBoundedResult -StdOut 'users kvm' } -ParameterFilter { $FilePath -eq 'id' }
        $member = "libvirt:x:973:$($script:User)"
        $partialGetent = @(
            (Get-FakeBoundedResult -StdOut $member -OutputTruncated),
            (Get-FakeBoundedResult -StdOut $member -DrainTimedOut),
            (Get-FakeBoundedResult -StdOut $member -KillFailed),
            (Get-FakeBoundedResult -ExitCode 2 -OutputTruncated)
        )
        foreach ($getentResult in $partialGetent) {
            Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { $getentResult }.GetNewClosure() -ParameterFilter { $FilePath -eq 'getent' }
            (Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm').Reason | Should -Be 'probe-failed'
        }
    }

    It 'needs nothing when libvirt is already in the running group set' {
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { Get-FakeBoundedResult -StdOut "users libvirt kvm`n" } -ParameterFilter { $FilePath -eq 'id' }
        (Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm').Reason | Should -Be 'in-active-set'
    }

    It 'needs nothing when the user is not a libvirt member or the group does not exist' {
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { Get-FakeBoundedResult -StdOut 'users kvm' } -ParameterFilter { $FilePath -eq 'id' }
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { Get-FakeBoundedResult -StdOut 'libvirt:x:973:someone,other' } -ParameterFilter { $FilePath -eq 'getent' }
        (Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm').Reason | Should -Be 'not-member'
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { Get-FakeBoundedResult -ExitCode 2 } -ParameterFilter { $FilePath -eq 'getent' }
        (Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm').Reason | Should -Be 'not-member'
    }

    It 'needs a relaunch for a member whose shell predates the membership, when sg exists' {
        # Built here: a closure's body cannot see this suite's helper functions.
        $getentResult = Get-FakeBoundedResult -StdOut "libvirt:x:973:someone,$($script:User)`n"
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { Get-FakeBoundedResult -StdOut 'users kvm' } -ParameterFilter { $FilePath -eq 'id' }
        Mock -ModuleName Test.HostDetection Invoke-BoundedNativeCommand { $getentResult }.GetNewClosure() -ParameterFilter { $FilePath -eq 'getent' }
        Mock -ModuleName Test.HostDetection Get-Command { [pscustomobject]@{ Name = 'sg'; Source = '/usr/bin/sg' } } -ParameterFilter { $Name -eq 'sg' }
        $d = Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm'
        $d.Needed | Should -Be $true
        $d.Reason | Should -Be 'relaunch-required'
        Mock -ModuleName Test.HostDetection Get-Command { $null } -ParameterFilter { $Name -eq 'sg' }
        (Test-LibvirtGroupReExecNeeded -HostType 'host.ubuntu.kvm').Reason | Should -Be 'no-sg'
    }
}

Describe 'ConvertTo-LibvirtRelaunchArgument -- parameters as command text' {
    It 'renders strings, numbers, switches, booleans and string arrays so they bind back unchanged' {
        $bound = [ordered]@{
            Name           = "it's a b"
            Count          = 5
            DeadlineTickMs = [long]3000000123
            Force          = [System.Management.Automation.SwitchParameter]::new($true)
            Unset          = [System.Management.Automation.SwitchParameter]::new($false)
            Flag           = $false
            On             = $true
            Items          = [string[]]@('a', "b 'c'")
            Single         = [string[]]@('only')
            Empty          = [string[]]@()
        }
        $parts = @(ConvertTo-LibvirtRelaunchArgument -BoundParameters $bound)
        $parts | Should -Contain "-Name 'it''s a b'"
        $parts | Should -Contain "-Count '5'"
        $parts | Should -Contain "-DeadlineTickMs '3000000123'"
        $parts | Should -Contain '-Force'
        $parts | Should -Contain '-Flag:$false'
        $parts | Should -Contain '-On:$true'
        $parts | Should -Contain "-Items 'a','b ''c'''"
        $parts | Should -Contain "-Single 'only'"
        $parts | Should -Contain '-Empty @()'
        @($parts | Where-Object { $_ -like '-Unset*' }).Count | Should -Be 0 -Because 'an absent switch is simply not forwarded'
        $parts.Count | Should -Be 9
    }

    It 'refuses a hashtable, an object and an injected name instead of flattening them' {
        { ConvertTo-LibvirtRelaunchArgument -BoundParameters @{ Policy = @{ tier = 'restart' } } } | Should -Throw
        { ConvertTo-LibvirtRelaunchArgument -BoundParameters @{ Deadline = [pscustomobject]@{ ExpiryTick = 1 } } } | Should -Throw
        { ConvertTo-LibvirtRelaunchArgument -BoundParameters @{ Items = @(@{ a = 1 }) } } | Should -Throw
        { ConvertTo-LibvirtRelaunchArgument -BoundParameters @{ 'x; Remove-Item ~' = 'v' } } | Should -Throw
        @(ConvertTo-LibvirtRelaunchArgument -BoundParameters @{}).Count | Should -Be 0
    }
}

Describe 'Invoke-LibvirtGroupReExecIfNeeded -- relaunch round trip' {
    It 'returns silently when no relaunch is needed' {
        $output = @(Invoke-LibvirtGroupReExecIfNeeded -HostType 'host.macos.utm' -ScriptPath $PSCommandPath -BoundParameters @{ Name = 'x' })
        $output.Count | Should -Be 0
    }

    It 'relaunches the calling script non-interactively with every parameter intact and returns its exit code' -Skip:$IsWindows {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-sg'
        try {
            $bin = New-FakeGroupTool -Directory $dir
            $record = Join-Path $dir 'bound.json'
            $trace = Join-Path $dir 'sg.trace'
            $caller = Join-Path $dir 'Invoke-Caller.ps1'
            $modulePath = $script:ModulePath -replace "'", "''"
            Set-Content -LiteralPath $caller -Encoding utf8 -Value @"
[CmdletBinding()]
param(
    [string]`$Name, [int]`$Count, [long]`$DeadlineTickMs, [double]`$Ratio, [switch]`$Force,
    [string[]]`$Items, [string[]]`$Single, [string[]]`$Empty, [bool]`$Flag
)
if (-not `$env:YURUNA_SG_RELAUNCH) {
    Import-Module '$modulePath' -DisableNameChecking
    `$forward = @{}
    foreach (`$key in `$PSBoundParameters.Keys) { `$forward[`$key] = `$PSBoundParameters[`$key] }
    # A computed value is added to a copy; assigning it in the script
    # would not put it in `$PSBoundParameters.
    `$forward['DeadlineTickMs'] = [long]3000000123
    Invoke-LibvirtGroupReExecIfNeeded -HostType 'host.ubuntu.kvm' -ScriptPath `$PSCommandPath -BoundParameters `$forward
    Write-Output 'NOT-RELAUNCHED'
    exit 3
}
`$seen = [ordered]@{
    bound          = @(`$PSBoundParameters.Keys | Sort-Object)
    name           = `$Name
    count          = `$Count
    deadlineTickMs = `$DeadlineTickMs
    ratio          = `$Ratio
    force          = [bool]`$Force
    items          = @(`$Items)
    single         = @(`$Single)
    emptyCount     = @(`$Empty).Count
    flag           = `$Flag
    relaunch       = `$env:YURUNA_SG_RELAUNCH
    nonInteractive = ([Environment]::GetCommandLineArgs() -contains '-NonInteractive')
}
[IO.File]::WriteAllText('$($record -replace "'", "''")', (`$seen | ConvertTo-Json -Compress -Depth 4))
exit 7
"@
            $callerText = $caller -replace "'", "''"
            $command = "& '$callerText' -Name 'it''s a b' -Count 5 -Ratio 1.5 -Force -Items 'a','b c' -Single 'only' -Empty @() -Flag:`$false; exit `$LASTEXITCODE"
            $pwshDir = Split-Path -Parent $script:Pwsh
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 120 `
                -Environment @{ PATH = "${bin}:${pwshDir}:$($env:PATH)"; SG_TRACE = $trace; USER = $script:User } `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $command)
            $r.TimedOut | Should -Be $false
            @(Get-BoundedNativeOutputLine -Result $r) | Should -Not -Contain 'NOT-RELAUNCHED'
            $r.ExitCode | Should -Be 7 -Because 'the relaunched script''s exit code is the parent''s exit code'
            (Get-Content -LiteralPath $trace -Raw).Trim() | Should -Be 'libvirt'

            $seen = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
            $seen.relaunch       | Should -Be '1'
            $seen.nonInteractive | Should -Be $true -Because 'an unattended relaunch must fail a prompt rather than wait on it'
            $seen.name           | Should -Be "it's a b"
            $seen.count          | Should -Be 5
            [long]$seen.deadlineTickMs | Should -Be 3000000123
            [double]$seen.ratio  | Should -Be 1.5
            $seen.force          | Should -Be $true
            @($seen.items)       | Should -Be @('a', 'b c')
            @($seen.single).Count | Should -Be 1
            @($seen.single)[0]   | Should -Be 'only'
            $seen.emptyCount     | Should -Be 0
            $seen.flag           | Should -Be $false
            @($seen.bound)       | Should -Contain 'Flag'
            @($seen.bound)       | Should -Contain 'Empty'
            @($seen.bound)       | Should -Contain 'DeadlineTickMs'
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'leaves the relaunched child unable to prompt even on a terminal where its parent can' -Skip:$script:SkipTerminalCase {
        # A -NonInteractive pwsh on a live terminal passes every console
        # probe, yet its Read-Host throws. The child must say it cannot
        # prompt, so a gated prompt site degrades instead of crashing.
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-sg'
        try {
            $bin = New-FakeGroupTool -Directory $dir
            $trace = Join-Path $dir 'sg.trace'
            $parentRecord = Join-Path $dir 'parent.prompt'
            $childRecord = Join-Path $dir 'child.prompt'
            $caller = Join-Path $dir 'Invoke-PromptCaller.ps1'
            $commonPath = (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -replace "'", "''"
            $modulePath = $script:ModulePath -replace "'", "''"
            Set-Content -LiteralPath $caller -Encoding utf8 -Value @"
Import-Module '$commonPath' -DisableNameChecking
if (-not `$env:YURUNA_SG_RELAUNCH) {
    [IO.File]::WriteAllText('$($parentRecord -replace "'", "''")', [string](Test-YurunaCanPrompt))
    Import-Module '$modulePath' -DisableNameChecking
    Invoke-LibvirtGroupReExecIfNeeded -HostType 'host.ubuntu.kvm' -ScriptPath `$PSCommandPath -BoundParameters @{}
    exit 3
}
[IO.File]::WriteAllText('$($childRecord -replace "'", "''")', [string](Test-YurunaCanPrompt))
exit 7
"@
            # script(1) runs its -c text through a shell: one quoted word per path.
            $quote = { param($Text) "'" + ("$Text" -replace "'", "'\''") + "'" }
            $terminalCommand = "$(& $quote $script:Pwsh) -NoProfile -File $(& $quote $caller)"
            $pwshDir = Split-Path -Parent $script:Pwsh
            $r = Invoke-BoundedNativeCommand -FilePath 'script' -TimeoutSeconds 120 `
                -Environment @{ PATH = "${bin}:${pwshDir}:$($env:PATH)"; SG_TRACE = $trace; USER = $script:User; YURUNA_NONINTERACTIVE = '' } `
                -ArgumentList @('-qec', $terminalCommand, '/dev/null')
            $r.TimedOut | Should -Be $false
            [IO.File]::Exists($parentRecord) | Should -Be $true -Because 'the caller must have run under the terminal'
            if ((Get-Content -LiteralPath $parentRecord -Raw).Trim() -ne 'True') {
                Set-ItResult -Skipped -Because 'script(1) gave the parent no usable terminal on this host, so the child''s answer would prove nothing'
                return
            }
            $r.ExitCode | Should -Be 7 -Because 'the relaunched script''s exit code is the parent''s exit code'
            (Get-Content -LiteralPath $trace -Raw).Trim() | Should -Be 'libvirt'
            (Get-Content -LiteralPath $childRecord -Raw).Trim() | Should -Be 'False' -Because 'a -NonInteractive pwsh throws at Read-Host, so it must report that it cannot prompt'
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'refuses a hashtable parameter before relaunching anything' -Skip:$IsWindows {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-sg'
        try {
            $bin = Join-Path $dir 'bin'
            $null = [IO.Directory]::CreateDirectory($bin)
            $fakes = @{
                'id'     = "#!/usr/bin/env bash`necho 'users kvm'`n"
                'getent' = "#!/usr/bin/env bash`necho `"libvirt:x:973:`$USER`"`n"
                'sg'     = "#!/usr/bin/env bash`ntouch `"`$SG_TRACE`"`nexit 0`n"
            }
            foreach ($name in $fakes.Keys) {
                $path = Join-Path $bin $name
                [IO.File]::WriteAllText($path, $fakes[$name])
                [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
            }
            $trace = Join-Path $dir 'sg.trace'
            $modulePath = $script:ModulePath -replace "'", "''"
            $command = "Import-Module '$modulePath' -DisableNameChecking; Invoke-LibvirtGroupReExecIfNeeded -HostType 'host.ubuntu.kvm' -ScriptPath '/nonexistent/x.ps1' -BoundParameters @{ Policy = @{ tier = 'restart' } }; exit 0"
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 90 `
                -Environment @{ PATH = "${bin}:$($env:PATH)"; SG_TRACE = $trace; USER = $script:User } `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $command)
            $r.ExitCode | Should -Not -Be 0
            [IO.File]::Exists($trace) | Should -Be $false -Because 'nothing may be relaunched with a value that cannot survive the relaunch'
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'documents the -Command relaunch it performs' {
        $help = Get-Help Invoke-LibvirtGroupReExecIfNeeded -Full | Out-String
        $help | Should -Match '-NonInteractive -Command'
        (Get-Help Invoke-LibvirtGroupReExecIfNeeded -Parameter ScriptPath | Out-String) | Should -Not -Match 'via `-File`'
    }
}

Describe 'Test-YurunaCanPrompt -- reading the host''s own -NonInteractive switch' {
    It 'recognizes every spelling pwsh accepts for -NonInteractive, and nothing else' {
        $common = @(Get-Module -Name Yuruna.Common)[0]
        $common | Should -Not -BeNullOrEmpty
        $probe = { param([string[]]$Line) Test-YurunaNonInteractiveHostArgument -ArgumentList $Line }
        foreach ($spelling in @('-NonInteractive', '-noni', '-NONI', '-nonint', '--noninteractive', ' -noni ')) {
            (& $common $probe @('pwsh', '-NoProfile', $spelling, '-Command', 'Get-Date')) | Should -Be $true -Because "pwsh reads '$spelling' as -NonInteractive"
        }
        $interactive = @(
            , @('pwsh', '-NoProfile', '-Command', 'Get-Date')
            , @('pwsh', '-non', '-File', 'a.ps1')
            , @('pwsh', '-noninteractivex')
            , @('pwsh', 'noni')
            , @('-NonInteractive')
            , @('pwsh', '-Command', 'Read-Host -noni')
            , @()
        )
        foreach ($line in $interactive) {
            (& $common $probe $line) | Should -Be $false -Because "'$($line -join ' ')' does not carry the switch"
        }
    }
}
