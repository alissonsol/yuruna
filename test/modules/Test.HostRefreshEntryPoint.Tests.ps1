<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42000a1f-befc-4d18-abeb-86563a85b9be
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh entry-point pester
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
    test/lab/Invoke-HostRefresh.ps1 in fresh -NoProfile processes, each with
    a scratch HOME, runtime, log and temp directory and stand-in native
    tools on a private PATH (virsh on Linux; utmctl, launchctl and pgrep on
    macOS): the native module closure a clean process resolves,
    fail-closed startup, an unknown switch, a preview that writes nothing,
    a healthy executing run, configuration resolution, the libvirt group
    relaunch round trip, two processes contending for the lifetime lock, a
    crashed worker resumed, the launcher wait, and the exit adapter. The
    only processes ever signaled are the ones a test started itself.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module Test.HostRefresh, Test.HostRefreshIntent | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostRefreshIntent.psm1') -Force -Global -DisableNameChecking
    $script:Entry = Join-Path $script:RepoRoot 'test/lab/Invoke-HostRefresh.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:UserName = [Environment]::UserName
    $script:NativeHostType = if ($IsMacOS) { 'host.macos.utm' } else { 'host.ubuntu.kvm' }
    $script:Created = [System.Collections.Generic.List[string]]::new()
    # One temp directory per run (TMPDIR decides where), removed in AfterAll.
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'yuruna-host-refresh-entry'
    # macOS TMPDIR commonly starts /var, which resolves through /private/var.
    # The worker records canonical paths, so fixture expectations must too.
    $script:ScratchBase = (Resolve-YurunaCanonicalPath -Path $script:ScratchBase).Path
    $script:Created.Add($script:ScratchBase)
    $script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:ParentModulePath = $env:PSModulePath

    $gate = @{ State = 'open' }
    ${function:global:Get-YurunaRefreshGateState} = {
        param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot)
        $null = $RuntimeDir, $TokenId, $PrivateRoot
        [pscustomobject]@{ State = $gate.State; RequestId = $null; Generation = ''; Reason = 'test' }
    }.GetNewClosure()

    function Write-Executable {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a stand-in tool into a private bin directory.')]
        param([string]$Path, [string]$Body)
        [IO.File]::WriteAllText($Path, "#!/bin/bash`n" + $Body.Replace("`r`n", "`n"))
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    }

    function New-EntryEnvironment {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates scratch directories and stand-in tools.')]
        param([string]$Probe = 'exit 0')
        $base = Join-Path $script:ScratchBase ('ep-' + [Guid]::NewGuid().ToString('N'))
        $script:Created.Add($base)
        $layout = [ordered]@{}
        foreach ($name in @('home', 'runtime', 'log', 'tmp', 'bin', 'pwsh-cache', 'pwsh-data', 'pwsh-config', 'work')) {
            $layout[$name] = Join-Path $base $name
            $null = New-Item -ItemType Directory -Path $layout[$name] -Force
        }
        Write-Executable -Path (Join-Path $layout.bin 'virsh') -Body $Probe
        if ($IsMacOS) {
            # Load the real macOS driver, but never send Apple Events to UTM.
            # Its native probes see a GUI session, a fixture-only process id
            # and a valid empty inventory. Unexpected mutations fail closed.
            Write-Executable -Path (Join-Path $layout.bin 'utmctl') -Body ('if [ "$*" != "list" ]; then exit 64; fi' + "`necho 'UUID Status Name'`n" + $Probe)
            Write-Executable -Path (Join-Path $layout.bin 'launchctl') -Body 'if [ "$*" = "managername" ]; then echo Aqua; exit 0; fi; exit 64'
            Write-Executable -Path (Join-Path $layout.bin 'pgrep') -Body 'if [ "$3 $4 $5" = "-i -x UTM" ]; then echo 2147483647; exit 0; fi; exit 1'
            foreach ($tool in @('open', 'osascript', 'killall', 'sudo')) {
                Write-Executable -Path (Join-Path $layout.bin $tool) -Body 'exit 64'
            }
        }
        $config = Join-Path $layout.work 'test.config.yml'
        [IO.File]::WriteAllText($config, "testCycle: {}`nstatusService:`n  enabled: false`n")
        $environment = @{
            HOME = $layout.home; YURUNA_RUNTIME_DIR = $layout.runtime; YURUNA_LOG_DIR = $layout.log; TMPDIR = $layout.tmp
            XDG_CACHE_HOME = $layout.'pwsh-cache'; XDG_DATA_HOME = $layout.'pwsh-data'; XDG_CONFIG_HOME = $layout.'pwsh-config'
            PSModulePath = $script:ParentModulePath; POWERSHELL_TELEMETRY_OPTOUT = '1'; POWERSHELL_UPDATECHECK = 'Off'
            DOTNET_EnableDiagnostics = '0'; NO_COLOR = '1'; USER = $script:UserName
            PATH = $layout.bin + [IO.Path]::PathSeparator + $env:PATH
        }
        [pscustomobject]@{ Base = $base; Home = $layout.home; Runtime = $layout.runtime; Log = $layout.log; Tmp = $layout.tmp; Bin = $layout.bin; Work = $layout.work; Config = $config; Environment = $environment }
    }

    function Start-EntryProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: starts a disposable process the suite owns.')]
        param([Parameter(Mandatory)]$Fixture, [string[]]$Argument = @(), [string]$Command, [hashtable]$ExtraEnvironment = @{})
        $info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($token in @('-NoLogo', '-NoProfile', '-NonInteractive')) { $info.ArgumentList.Add($token) }
        if ($Command) { $info.ArgumentList.Add('-Command'); $info.ArgumentList.Add($Command) }
        else { $info.ArgumentList.Add('-File'); $info.ArgumentList.Add($script:Entry); foreach ($token in $Argument) { $info.ArgumentList.Add($token) } }
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.RedirectStandardInput = $true
        $info.UseShellExecute = $false
        $info.WorkingDirectory = $Fixture.Work
        foreach ($name in @('YURUNA_SG_RELAUNCH', 'YURUNA_NONINTERACTIVE', 'YURUNA_DETACH_HANDSHAKE', 'YURUNA_DETACH_HOP_PID', 'YURUNA_DETACH_HOP_START',
                'YURUNA_REFRESH_HANDOFF_TOKEN', 'YURUNA_REFRESH_PREFLIGHT', 'YURUNA_REFRESH_BARRIER', 'YURUNA_CYCLE_GENERATION')) { $null = $info.Environment.Remove($name) }
        foreach ($key in $Fixture.Environment.Keys) { $info.Environment[$key] = [string]$Fixture.Environment[$key] }
        foreach ($key in $ExtraEnvironment.Keys) { $info.Environment[$key] = [string]$ExtraEnvironment[$key] }
        $process = [System.Diagnostics.Process]::Start($info)
        $process.StandardInput.Close()
        $script:Spawned.Add($process)
        [pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
    }

    function Wait-EntryProcess {
        param([Parameter(Mandatory)]$Started, [int]$TimeoutSeconds = 180)
        if (-not $Started.Process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $Started.Process.Kill($true) } catch { $null = $_ }
            throw "the entry process did not finish within $TimeoutSeconds s"
        }
        $Started.Process.WaitForExit()
        $text = ([string]$Started.Out.Result + "`n" + [string]$Started.Err.Result) -replace '\x1b\[[0-9;]*[A-Za-z]', ''
        [pscustomobject]@{ ExitCode = $Started.Process.ExitCode; Output = $text }
    }

    function Invoke-EntryProcess {
        param([Parameter(Mandatory)]$Fixture, [string[]]$Argument = @(), [string]$Command, [hashtable]$ExtraEnvironment = @{}, [int]$TimeoutSeconds = 180)
        Wait-EntryProcess -Started (Start-EntryProcess -Fixture $Fixture -Argument $Argument -Command $Command -ExtraEnvironment $ExtraEnvironment) -TimeoutSeconds $TimeoutSeconds
    }

    function Get-TreeListing {
        param([string[]]$Path)
        foreach ($root in $Path) {
            foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue)) {
                '{0}|{1}|{2}' -f $item.FullName, $(if ($item.PSIsContainer) { 'd' } else { $item.Length }), $item.LastWriteTimeUtc.Ticks
            }
            '{0}|root|{1}' -f $root, ([IO.Directory]::GetLastWriteTimeUtc($root)).Ticks
        }
    }

    function Read-EntryJournal {
        param([Parameter(Mandatory)]$Fixture)
        $path = Join-Path $Fixture.Home '.yuruna/host-refresh/host-refresh.journal'
        $record = Read-YurunaCriticalRecord -Path $path -Kind 'host-refresh.request-journal' -MaxBytes 4194304
        if ($record.Status -ne 'ok') { return $null }
        $record.Payload
    }

    function Get-PreviewPlan {
        param([Parameter(Mandatory)]$Fixture, [string]$ExtraArgument = '')
        $command = "`$plan = & '$($script:Entry)' -WhatIf $ExtraArgument 6>`$null 3>`$null; 'JSON:' + (`$plan | ConvertTo-Json -Depth 6 -Compress); 'EXIT=' + `$LASTEXITCODE"
        $run = Invoke-EntryProcess -Fixture $Fixture -Command $command
        $line = @($run.Output -split "`n" | Where-Object { $_.StartsWith('JSON:') })[0]
        $plan = if ($line) { $line.Substring(5) | ConvertFrom-Json -AsHashtable } else { $null }
        [pscustomobject]@{ Plan = $plan; Output = $run.Output; ExitCode = $run.ExitCode }
    }

    function Add-EntryEnvelope {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a configuration snapshot envelope into a scratch runtime.')]
        param([string]$Runtime, [string]$Source)
        $name = '.test.config.snapshot.' + [Guid]::NewGuid().ToString('N').Substring(0, 12) + '.json'
        $body = @{ sourcePath = $Source; publisherPid = 1; config = @{ testCycle = @{}; statusService = @{ enabled = $false } } } | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText((Join-Path $Runtime $name), $body)
    }
}

AfterAll {
    foreach ($process in $script:Spawned) {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { $null = $_ }
    }
    Remove-Item -LiteralPath Function:\Get-YurunaRefreshGateState -ErrorAction SilentlyContinue
    foreach ($dir in $script:Created) { Remove-YurunaTestTempDir $dir }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'startup and the module closure' -Skip:$IsWindows {
    It 'resolves every command the worker needs, from its recorded module, in a clean process' {
        $fixture = New-EntryEnvironment
        $command = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$($script:RepoRoot)/test/modules/Test.Prelude.psm1' -Global -Force -DisableNameChecking
`$paths = Initialize-YurunaEntryPoint -ScriptRoot '$($script:RepoRoot)/test/lab' -InsideSubfolder
Initialize-YurunaEntryPointModuleSet -For Refresh -ModulesDir `$paths.ModulesDir 3>`$null
Import-Module powershell-yaml -Global
`$hostType = Get-HostType
[void](Initialize-YurunaHost -RepoRoot `$paths.RepoRoot -HostType `$hostType)
foreach (`$row in @(Get-HostRefreshRequiredCommand -HostType `$hostType)) {
    `$c = Get-Command `$row.Name -ErrorAction SilentlyContinue
    'ROW:{0}|{1}|{2}' -f `$row.Name, `$row.Module, `$(if (`$c) { `$c.Source } else { 'MISSING' })
}
`$config = Read-TestConfig -Path '$($fixture.Config)'
'YAML:' + [bool]`$config['statusService']['enabled']
"@
        $run = Invoke-EntryProcess -Fixture $fixture -Command $command
        $rows = @($run.Output -split "`n" | Where-Object { $_.StartsWith('ROW:') } | ForEach-Object { $_.Substring(4).Trim() })
        Assert-True ($rows.Count -ge 30) "resolved $($rows.Count) rows"
        $findings = foreach ($row in $rows) {
            $name, $module, $source = $row -split '\|'
            if ($source -ne $module) { "$name comes from '$source', recorded as '$module'" }
        }
        Assert-NoFinding @($findings) 'every required command resolves from its recorded module'
        Assert-True ($run.Output -match 'YAML:False') 'Read-TestConfig reads a fixture through powershell-yaml'
    }

    It 'fails closed, with a nonzero exit, when a module of the set is missing' {
        $fixture = New-EntryEnvironment
        $overlay = Join-Path $fixture.Base 'overlay'
        foreach ($name in @('automation', 'host', 'globalization', 'VERSION')) {
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $overlay $name) -Target (Join-Path $script:RepoRoot $name) -Force
        }
        $null = New-Item -ItemType Directory -Path (Join-Path $overlay 'test/lab'), (Join-Path $overlay 'test/modules') -Force
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $overlay 'test/lab/Invoke-HostRefresh.ps1') -Target $script:Entry
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $overlay 'test/host-refresh.protocol-version') -Target (Join-Path $script:RepoRoot 'test/host-refresh.protocol-version')
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test/modules') -File)) {
            if ($file.Name -eq 'Test.OuterLog.psm1') { continue }
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $overlay "test/modules/$($file.Name)") -Target $file.FullName
        }
        $command = "& '$overlay/test/lab/Invoke-HostRefresh.ps1' -WhatIf; exit `$LASTEXITCODE"
        $run = Invoke-EntryProcess -Fixture $fixture -Command $command
        Assert-Equal 1 $run.ExitCode
        Assert-True ($run.Output -match 'host_refresh_command_missing|Write-OuterLog|Test\.OuterLog') 'the missing command is named'
        Assert-False ($run.Output -match '"phase"\s*:\s*"preview"|phase\s*:\s*preview') 'no plan is produced'
    }

    It 'refuses an unknown or misspelled switch and changes nothing' {
        $fixture = New-EntryEnvironment
        $before = @(Get-TreeListing -Path $fixture.Home, $fixture.Runtime, $fixture.Log, $fixture.Tmp)
        foreach ($arguments in @(@('-Tierr', 'restart'), @('-Bogus'), @('-RequestId', 'not-a-uuid'), @('-Force', '-RequestId', '4242aaaa-0000-4000-8000-000000000001'))) {
            $run = Invoke-EntryProcess -Fixture $fixture -Argument $arguments
            Assert-NotEqual 0 $run.ExitCode "arguments $($arguments -join ' ')"
        }
        $after = @(Get-TreeListing -Path $fixture.Home, $fixture.Runtime, $fixture.Log, $fixture.Tmp)
        Assert-Equal ($before -join "`n") ($after -join "`n")
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'preview and a healthy executing run' -Skip:$IsWindows {
    It 'previews with exit 0, one plan object and not a single byte written' {
        $fixture = New-EntryEnvironment
        $before = @(Get-TreeListing -Path $fixture.Home, $fixture.Runtime, $fixture.Log, $fixture.Tmp)
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-WhatIf')
        $after = @(Get-TreeListing -Path $fixture.Home, $fixture.Runtime, $fixture.Log, $fixture.Tmp)
        Assert-Equal 0 $run.ExitCode
        Assert-Equal ($before -join "`n") ($after -join "`n") 'the preview wrote nothing, not even a transient file'
        $preview = Get-PreviewPlan -Fixture $fixture
        Assert-Equal 'preview' $preview.Plan['phase']
        Assert-Equal 'Responsive' $preview.Plan['probe']['state']
        Assert-Equal 'EXIT=0' (@($preview.Output -split "`n" | Where-Object { $_.StartsWith('EXIT=') })[0].Trim())
    }

    It 'runs a healthy host to already-healthy, recording the journal, the public state and outer.log, and nothing else' {
        $fixture = New-EntryEnvironment
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-ConfigPath', $fixture.Config)
        Assert-Equal 0 $run.ExitCode
        $journal = Read-EntryJournal -Fixture $fixture
        Assert-NotNull $journal 'the journal was written'
        $request = @($journal['requests'])[0]
        Assert-Equal 'completed' $request['state']
        Assert-Equal 'already-healthy' $request['verdict']
        Assert-Equal 1 @($journal['tombstones']).Count
        Assert-Equal $fixture.Config $request['context']['configPath']
        $statePath = Join-Path $fixture.Runtime 'host-refresh.state.json'
        $bytes = [IO.File]::ReadAllBytes($statePath)
        Assert-False ($bytes[0] -eq 0xEF) 'no byte-order mark'
        $state = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable
        Assert-Equal 'terminal' $state['phase']
        Assert-Equal 'already_healthy' $state['verdict']
        Assert-Equal ('schemaVersion,requestId,generation,attempt,channel,phase,state,heartbeatUtc,startedUtc,updatedUtc,step,remainingBudgetMs,' +
            'reasonCodes,reportDegraded,mutated,verdict,operatorAction,terminalUtc') (@($state.Keys) -join ',')
        Assert-True ((Get-Content -LiteralPath (Join-Path $fixture.Runtime 'outer.log')).Count -ge 1) 'outer.log gained lines'
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Log 'cycle.events.ndjson'))
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Log 'last_failure.json'))
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Runtime 'status.json'))
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'configuration resolution' -Skip:$IsWindows {
    It 'canonicalizes an explicit configuration reached through a link' {
        $fixture = New-EntryEnvironment
        $alias = Join-Path $fixture.Base 'alias'
        $null = New-Item -ItemType SymbolicLink -Path $alias -Target $fixture.Work
        $preview = Get-PreviewPlan -Fixture $fixture -ExtraArgument "-ConfigPath '$alias/test.config.yml'"
        Assert-Equal 'explicit' $preview.Plan['context']['configSource']
        Assert-Equal $fixture.Config $preview.Plan['context']['configPath']
    }

    It 'uses one snapshot envelope, refuses several sources and a missing one, and otherwise takes the default' {
        $fixture = New-EntryEnvironment
        $none = Get-PreviewPlan -Fixture $fixture
        Assert-Equal 'default' $none.Plan['context']['configSource']
        Add-EntryEnvelope -Runtime $fixture.Runtime -Source $fixture.Config
        Assert-Equal 'snapshot-envelope' (Get-PreviewPlan -Fixture $fixture).Plan['context']['configSource']
        $other = Join-Path $fixture.Work 'other.yml'
        [IO.File]::WriteAllText($other, "testCycle: {}`n")
        Add-EntryEnvelope -Runtime $fixture.Runtime -Source $other
        $ambiguous = Get-PreviewPlan -Fixture $fixture
        Assert-Equal 'config-ambiguous' $ambiguous.Plan['context']['reason']
        Assert-Equal 1 (Invoke-EntryProcess -Fixture $fixture).ExitCode 'an executing run refuses an ambiguous configuration'
        Get-ChildItem -LiteralPath $fixture.Runtime -Force -Filter '.test.config.snapshot.*' | Remove-Item -Force
        Add-EntryEnvelope -Runtime $fixture.Runtime -Source (Join-Path $fixture.Work 'gone.yml')
        Assert-Equal 'config-missing' (Get-PreviewPlan -Fixture $fixture).Plan['context']['reason']
    }

    It 'refuses a runtime other than the one this account registered' {
        $fixture = New-EntryEnvironment
        $root = Join-Path $fixture.Home '.yuruna/host-refresh'
        $null = New-Item -ItemType Directory -Path $root -Force
        [IO.File]::SetUnixFileMode($root, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        $payload = [ordered]@{ schemaVersion = 2; writtenUtc = ''; owner = @{ runtimeDir = $fixture.Work }; requests = @(); reservations = @(); tombstones = @() }
        $null = Write-YurunaCriticalRecord -Path (Join-Path $root 'host-refresh.journal') -Kind 'host-refresh.request-journal' -Payload $payload -ExpectedGeneration 0 -Confirm:$false
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-ConfigPath', $fixture.Config)
        Assert-Equal 1 $run.ExitCode
        Assert-Equal 0 @((Read-EntryJournal -Fixture $fixture)['requests']).Count 'nothing was claimed'
    }
}

Describe 'the libvirt group relaunch' {
    It 'relaunches once through sg, forwarding the budget ticks and every array element, and exits with the child''s code' {
        if (-not $IsLinux) { Set-ItResult -Skipped -Because 'libvirt group relaunch is a Linux-only entry-point branch'; return }
        $fixture = New-EntryEnvironment
        $counter = Join-Path $fixture.Work 'sg.count'
        Write-Executable -Path (Join-Path $fixture.Bin 'id') -Body "if [ `"`$1`" = '-nG' ]; then echo '$($script:UserName) adm'; exit 0; fi`nexec /usr/bin/id `"`$@`"`n"
        Write-Executable -Path (Join-Path $fixture.Bin 'getent') -Body "if [ `"`$1 `$2`" = 'group libvirt' ]; then echo 'libvirt:x:999:$($script:UserName)'; exit 0; fi`nexec /usr/bin/getent `"`$@`"`n"
        Write-Executable -Path (Join-Path $fixture.Bin 'sg') -Body "echo 1 >> '$counter'`nexec bash -c `"`$3`"`n"
        $tick = [Environment]::TickCount64 + 600000
        $command = "& '$($script:Entry)' -ConfigPath '$($fixture.Config)' -RestoreServiceVmName 'yuruna-a','yuruna-b' -DeadlineTickMs $tick; exit `$LASTEXITCODE"
        $run = Invoke-EntryProcess -Fixture $fixture -Command $command
        Assert-Equal 0 $run.ExitCode 'the parent exits with the relaunched child''s code'
        Assert-Equal 1 @(Get-Content -LiteralPath $counter).Count 'exactly one relaunch'
        $request = @((Read-EntryJournal -Fixture $fixture)['requests'])[0]
        Assert-Equal 'yuruna-a,yuruna-b' (@($request['policy']['restoreServiceVmName']) -join ',')
        Assert-Equal $tick ([long]@($request['attempts'])[0]['budget']['totalExpiryTick']) 'the child kept the parent''s budget'
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'serialization and crash recovery' -Skip:$IsWindows {
    It 'refuses a second run while the first holds the lifetime lock' {
        $barrier = 'barrier.' + [Guid]::NewGuid().ToString('N')
        $fixture = New-EntryEnvironment -Probe "if [ ! -e `"`$TMPDIR/../work/$barrier`" ]; then touch `"`$TMPDIR/../work/$barrier`"; sleep 8; fi`nexit 0`n"
        $first = Start-EntryProcess -Fixture $fixture -Argument @('-ConfigPath', $fixture.Config)
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath (Join-Path $fixture.Work $barrier)) -and $wait.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Milliseconds 100 }
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Work $barrier)) 'the first run reached its probe'
        $second = Invoke-EntryProcess -Fixture $fixture -Argument @('-ConfigPath', $fixture.Config)
        Assert-Equal 1 $second.ExitCode
        Assert-True ($second.Output -match 'host_refresh_lock_busy|lifetime lock')
        $firstDone = Wait-EntryProcess -Started $first
        Assert-Equal 0 $firstDone.ExitCode
        Assert-Equal 1 @((Read-EntryJournal -Fixture $fixture)['requests']).Count 'only the first run claimed a request'
    }

    It 'resumes a crashed worker''s request as its second attempt' {
        $barrier = 'barrier.' + [Guid]::NewGuid().ToString('N')
        $fixture = New-EntryEnvironment -Probe "if [ ! -e `"`$TMPDIR/../work/$barrier`" ]; then touch `"`$TMPDIR/../work/$barrier`"; sleep 120; fi`nexit 0`n"
        $crashing = Start-EntryProcess -Fixture $fixture -Argument @('-ConfigPath', $fixture.Config)
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath (Join-Path $fixture.Work $barrier)) -and $wait.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Milliseconds 100 }
        $crashing.Process.Kill($true)
        $crashing.Process.WaitForExit()
        $request = @((Read-EntryJournal -Fixture $fixture)['requests'])[0]
        Assert-Equal 'running' $request['state'] 'the killed worker left its claim'
        $resume = Invoke-EntryProcess -Fixture $fixture -Argument @('-Resume')
        Assert-Equal 0 $resume.ExitCode
        $request = @((Read-EntryJournal -Fixture $fixture)['requests'])[0]
        Assert-Equal 2 $request['attempt']
        Assert-Equal 'completed' $request['state']
    }

    It 'records a disposition while the configuration is ambiguous and the recorded one is gone' {
        $fixture = New-EntryEnvironment
        & (Get-Module Test.HostRefreshIntent) { param($h) $script:HostRefreshHomePath = $h } $fixture.Home
        try {
            $lock = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostRefreshLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
            try {
                $id = New-YurunaHostRefreshRequestId
                $worker = @{ pid = $PID; startTimeUnixMs = [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds(); ownerId = [string](Get-YurunaCurrentOwnerId).OwnerId; parent = $null }
                $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $id -Policy @{ Tier = 'restart' } -Worker $worker -RuntimeDir $fixture.Runtime `
                    -RepoRoot $script:RepoRoot -HostType $script:NativeHostType -Context @{ configPath = $fixture.Config } -Confirm:$false
                Assert-True $claim.Accepted $claim.Reason
                $null = Save-HostRefreshRecoveryRecord -RequestId $id -Generation $claim.Generation -Recovery @{ configPath = (Join-Path $fixture.Work 'gone.yml') } `
                    -Obligation @(@{ id = 'listener'; kind = 'listener'; target = 'listener' }) -Confirm:$false
                $null = Set-HostRefreshObligationState -RequestId $id -Generation $claim.Generation -ObligationId @('listener') -State armed -Confirm:$false
                $null = Complete-HostRefreshAttempt -RequestId $id -Generation $claim.Generation -Verdict 'partial' -Mutated $true -ReasonCode @() -RungResult @() -Confirm:$false
            } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        } finally {
            & (Get-Module Test.HostRefreshIntent) { $script:HostRefreshHomePath = $null }
        }
        Add-EntryEnvelope -Runtime $fixture.Runtime -Source $fixture.Config
        $other = Join-Path $fixture.Work 'other.yml'
        [IO.File]::WriteAllText($other, "testCycle: {}`n")
        Add-EntryEnvelope -Runtime $fixture.Runtime -Source $other
        $resume = Invoke-EntryProcess -Fixture $fixture -Argument @('-Resume')
        Assert-Equal 1 $resume.ExitCode 'a retry needs its recorded configuration, which is gone'
        $dispose = Invoke-EntryProcess -Fixture $fixture -Argument @('-DisposeObligation', 'listener')
        Assert-Equal 0 $dispose.ExitCode 'a disposition needs no configuration at all'
        $request = @((Read-EntryJournal -Fixture $fixture)['requests'] | Where-Object { $_['requestId'] -eq $id })[0]
        Assert-Equal 'completed' $request['state']
        Assert-Equal 'disposed' (@($request['obligations'] | Where-Object { $_['id'] -eq 'listener' })[0]['status'])
        Assert-Equal $script:UserName (@($request['obligations'] | Where-Object { $_['id'] -eq 'listener' })[0]['disposedBy'])
    }

    It 'waits for its launcher to exit before claiming, and leaves the request queued when the launcher outlives startup' {
        $fixture = New-EntryEnvironment
        & (Get-Module Test.HostRefreshIntent) { param($h) $script:HostRefreshHomePath = $h } $fixture.Home
        try {
            $id = New-YurunaHostRefreshRequestId
            $admitted = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType $script:NativeHostType `
                -Context @{ configPath = $fixture.Config } -Confirm:$false
            Assert-Equal 'spawn' $admitted.Decision
            $short = Start-Process -FilePath $script:Pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep 3') -PassThru
            $script:Spawned.Add($short)
            $hop = @{ YURUNA_DETACH_HOP_PID = "$($short.Id)"; YURUNA_DETACH_HOP_START = "$([DateTimeOffset]::new($short.StartTime).ToUnixTimeMilliseconds())" }
            $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-RequestId', $id) -ExtraEnvironment $hop
            Assert-Equal 0 $run.ExitCode
            Assert-True $short.HasExited 'the worker claimed only after its launcher exited'
            Assert-Equal 'completed' (Read-YurunaHostRefreshRequest -RequestId $id)['state']
            $second = New-YurunaHostRefreshRequestId
            $null = Request-HostRefreshAdmission -RequestId $second -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType $script:NativeHostType `
                -Context @{ configPath = $fixture.Config } -Confirm:$false
            $long = Start-Process -FilePath $script:Pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep 120') -PassThru
            $script:Spawned.Add($long)
            $hop = @{ YURUNA_DETACH_HOP_PID = "$($long.Id)"; YURUNA_DETACH_HOP_START = "$([DateTimeOffset]::new($long.StartTime).ToUnixTimeMilliseconds())" }
            $timeout = Invoke-EntryProcess -Fixture $fixture -Argument @('-RequestId', $second, '-PreAdmissionDeadlineTickMs', "$([Environment]::TickCount64 + 8000)") -ExtraEnvironment $hop
            Assert-Equal 1 $timeout.ExitCode
            Assert-Equal 'queued' (Read-YurunaHostRefreshRequest -RequestId $second)['state'] 'the request stays queued for a retry'
            $long.Kill()
        } finally {
            & (Get-Module Test.HostRefreshIntent) { $script:HostRefreshHomePath = $null }
        }
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'the exit adapter and the caller''s session' -Skip:$IsWindows {
    It 'exits explicitly and restores an in-process caller''s preferences and environment' {
        $fixture = New-EntryEnvironment
        $command = @"
bash -c 'exit 7'
& '$($script:Entry)' -WhatIf *> `$null
'PREVIEW=' + `$LASTEXITCODE
& '$($script:Entry)' -ConfigPath '$($fixture.Work)/missing.yml' *> `$null
'REFUSED=' + `$LASTEXITCODE
Remove-Item Env:YURUNA_NONINTERACTIVE -ErrorAction SilentlyContinue
`$env:YURUNA_LOG_DIR = '$($fixture.Log)'
`$ConfirmPreference = 'Low'
& '$($script:Entry)' -WhatIf *> `$null
'CONFIRM=' + `$ConfirmPreference
'NONINTERACTIVE=' + (Test-Path Env:YURUNA_NONINTERACTIVE)
'RUNTIME=' + `$env:YURUNA_RUNTIME_DIR
'LOG=' + `$env:YURUNA_LOG_DIR
"@
        $run = Invoke-EntryProcess -Fixture $fixture -Command $command
        $lines = @($run.Output -split "`n" | ForEach-Object { $_.Trim() })
        Assert-True ($lines -contains 'PREVIEW=0') 'a preview sets exit code 0 over a previous native code'
        Assert-True ($lines -contains 'REFUSED=1')
        Assert-True ($lines -contains 'CONFIRM=Low')
        Assert-True ($lines -contains 'NONINTERACTIVE=False') 'an unset variable is removed again, not left empty'
        Assert-True ($lines -contains "RUNTIME=$($fixture.Runtime)")
        Assert-True ($lines -contains "LOG=$($fixture.Log)")
    }
}
