<#PSScriptInfo
.VERSION 2026.09.27
.GUID 424389c7-e56a-4c48-9b73-1d24e21c6aa1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service refresh-safe start pester
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
    Start-StatusService.ps1 -RefreshSafe starts a listener only when it is
    positively absent and disturbs nothing else.
.DESCRIPTION
    The normal start takes a port from its holder, stops a live server whose
    commit changed, sweeps control files and rewrites status.json; each of
    those is right for a cycle start and wrong for a refresh that is trying
    to restore a host without undoing what an operator or a held runner left
    in place. Two kinds of evidence here:

      * a static guard over the launcher's own syntax tree: every call that
        stops, takes, sweeps, rewrites, elevates or runs an unbounded native
        command sits behind a condition the refresh-safe start cannot pass;
      * child-process runs of the real script against a scratch runtime and
        HOME on an ephemeral port, one per outcome that needs no new server,
        checking the exit code, the result record, and that every stand-in
        and control file survived.

    ANSI sequences are stripped from captured output before any assertion.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.StatusControlRoute.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.SingleInstance.psm1') -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:ServicePath = Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1'
$script:Pwsh = (Get-Process -Id $PID).Path
$script:ParentAst = Get-YurunaTestFileAst -Path $script:ServicePath

function Test-RefreshSafeGuarded {
    <#
    .SYNOPSIS
        Whether an AST node can only run when the refresh-safe switch is off.
    .DESCRIPTION
        Walks up from the node. It is guarded when an enclosing if-clause
        condition reads "-not $RefreshSafe" or tests $Restart (a Normal-only
        parameter), when it sits in the else branch or a later elseif of an
        "if ($RefreshSafe)", or when it is inside a function only Normal code
        calls.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Node)
    $child = $Node
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
            for ($i = 0; $i -lt $parent.Clauses.Count; $i++) {
                $condition = $parent.Clauses[$i].Item1.Extent.Text
                $body = $parent.Clauses[$i].Item2
                if ([object]::ReferenceEquals($body, $child)) {
                    if ($condition -match '-not \$RefreshSafe' -or $condition -match '^\$Restart\b') { return $true }
                    if ($i -gt 0 -and $parent.Clauses[0].Item1.Extent.Text -eq '$RefreshSafe') { return $true }
                }
            }
            if ([object]::ReferenceEquals($parent.ElseClause, $child) -and $parent.Clauses[0].Item1.Extent.Text -eq '$RefreshSafe') { return $true }
        }
        $child = $parent
        $parent = $parent.Parent
    }
    return $false
}
}

Describe 'the refresh-safe start reaches no destructive call' {

    It 'declares strict binding with separate Normal and RefreshSafe parameter sets' {
        $attribute = $script:ParentAst.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        Assert-NotNull $attribute 'the launcher must declare [CmdletBinding()] so an unknown switch is refused'
        Assert-Match "DefaultParameterSetName\s*=\s*'Normal'" $attribute.Extent.Text
        $parameters = @{}
        foreach ($parameter in $script:ParentAst.ParamBlock.Parameters) { $parameters[$parameter.Name.VariablePath.UserPath] = $parameter.Extent.Text }
        Assert-Match "ParameterSetName = 'RefreshSafe', Mandatory" $parameters['RefreshSafe']
        Assert-Match "ParameterSetName = 'Normal'" $parameters['Restart']
        Assert-Match "ParameterSetName = 'RefreshSafe', Mandatory" $parameters['Port'] 'a refresh-safe start always names its port'
        Assert-Match "ParameterSetName = 'RefreshSafe'" $parameters['ResultPath']
        Assert-Match "ParameterSetName = 'RefreshSafe'" $parameters['DeadlineTickMs']
    }

    It 'keeps every stop, takeover, sweep, rewrite, elevation and unbounded native call behind a Normal-only condition' {
        $destructive = @('Stop-Process', 'Resolve-PortOrphan', 'Add-PortMap', 'Remove-PortMap', 'Set-YurunaStatusFirewallRule',
            'git', 'hostname', 'sudo', 'Initialize-YurunaHost', 'Enter-CachingProxyServiceLock', 'Test-CachingProxyServiceAvailable')
        $findings = @()
        $visited = @{}
        $commands = $script:ParentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands) {
            $name = $command.GetCommandName()
            if (-not $name) { continue }
            if ($name -eq 'Initialize-YurunaRuntimeDir') {
                Assert-False (Test-RefreshSafeGuarded -Node $command) 'the guard walk must not pass an unguarded call'
            }
            $isDestructive = $destructive -contains $name
            if ($isDestructive) { $visited[$name] = 1 + [int]$visited[$name] }
            if ($name -eq 'Remove-Item' -and $command.Extent.Text -match "break-active|control\.|server\.heartbeat|LegacyTrackDir|legacyName|\`$PidFile") { $isDestructive = $true }
            if (-not $isDestructive) { continue }
            if (-not (Test-RefreshSafeGuarded -Node $command)) { $findings += "line $($command.Extent.StartLineNumber): $($command.Extent.Text)" }
        }
        foreach ($member in $script:ParentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            $text = $member.Extent.Text
            if ($text -match 'WriteAllText\(\$StatusFile' -or $text -match 'GetHostAddresses') {
                if (-not (Test-RefreshSafeGuarded -Node $member)) { $findings += "line $($member.Extent.StartLineNumber): $text" }
            }
        }
        foreach ($name in @('Stop-Process', 'Resolve-PortOrphan', 'Add-PortMap', 'Remove-PortMap', 'Set-YurunaStatusFirewallRule', 'git', 'hostname', 'sudo')) {
            Assert-True ($visited[$name] -ge 1) "the scan found no $name call, so it proves nothing about it"
        }
        Assert-NoFinding $findings 'a call the refresh-safe start must never make is reachable in that mode'
    }

    It 'bounds its own git call and never restarts a server for a changed commit' {
        $sha = @($script:ParentAst.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RefreshSafeFrameworkSha'
                }, $true))
        Assert-Equal 1 $sha.Count
        Assert-Match 'Invoke-BoundedNativeCommand -FilePath ''git''' $sha[0].Extent.Text
        Assert-Match 'Get-YurunaDeadlineBoundedSeconds -Deadline \$script:RefreshSafeDeadline' $sha[0].Extent.Text
    }

    It 'lets an error raised before the startup-lock helper exists reach the caller unchanged' {
        # A trap covers its whole scope, the module imports before the
        # helper's definition included; an unguarded call there would replace
        # the real error with "not recognized".
        $traps = @($script:ParentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TrapStatementAst] }, $false))
        Assert-Equal 1 $traps.Count 'the launcher has one script-level trap'
        $releases = @($traps[0].Body.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Exit-StatusServiceStartupLock' }, $true))
        Assert-True ($releases.Count -ge 1) 'the trap still releases the startup lock'
        foreach ($release in $releases) {
            $guard = $release.Parent
            while ($null -ne $guard -and $guard -isnot [System.Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
            Assert-NotNull $guard 'the release in the trap is conditional'
            Assert-Match "Get-Command -Name 'Exit-StatusServiceStartupLock'" $guard.Clauses[0].Item1.Extent.Text 'the release runs only once the helper exists'
        }
        $statements = @($traps[0].Body.Statements)
        Assert-Match '^break$' $statements[-1].Extent.Text.Trim() 'the error still propagates'
    }

    It 'bakes the configuration path on every branch' {
        $text = [IO.File]::ReadAllText($script:ServicePath)
        $needle = '`$serverConfigPath = ' + "'" + '$($ServerConfigPath -replace'
        Assert-True $text.Contains($needle) 'the generated server gets the escaped, always-resolved config path'
        Assert-Match '\$ServerConfigPath = Join-Path \$TestRoot ''test.config.yml''' $text
    }
}

Describe 'the refresh-safe start in its own process' {

    BeforeAll {
        function New-RefreshSafeScratch {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Creates a throwaway test tree.')]
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param()
            $root = New-YurunaTestTempDir -Prefix 'yuruna-refresh-safe'
            $scratch = [pscustomobject]@{
                Root = $root; Home = (Join-Path $root 'home'); Runtime = (Join-Path $root 'runtime'); Log = (Join-Path $root 'log')
                Out = (Join-Path $root 'out'); Result = (Join-Path $root 'out/result.json')
            }
            $null = New-Item -ItemType Directory -Path $scratch.Home, $scratch.Runtime, $scratch.Log, $scratch.Out
            foreach ($name in @('control.cycle-pause', 'control.step-pause', 'control.lab-hold', 'lab-hold.json', 'break-active.json', 'control.break-continue', 'control.cycle-restart')) {
                [IO.File]::WriteAllText((Join-Path $scratch.Runtime $name), "held:$name")
            }
            [IO.File]::WriteAllText((Join-Path $scratch.Runtime 'status.json'), '{"overallStatus":"running","cyclePaused":true}')
            return $scratch
        }

        function Get-RuntimeSnapshot {
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([Parameter(Mandatory)]$Scratch)
            $snapshot = @{}
            foreach ($file in @(Get-ChildItem -LiteralPath $Scratch.Runtime -Force -File)) { $snapshot[$file.Name] = [IO.File]::ReadAllText($file.FullName) }
            return $snapshot
        }

        function Get-FreePort {
            [CmdletBinding()]
            [OutputType([int])]
            param()
            $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $probe.Start()
            try { return $probe.LocalEndpoint.Port } finally { $probe.Stop() }
        }

        function Invoke-RefreshSafeStart {
            <#
            .SYNOPSIS
                Run the launcher as its own process under the scratch HOME and runtime.
            #>
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param(
                [Parameter(Mandatory)]$Scratch,
                [string[]]$Argument,
                [switch]$NoRuntime
            )
            $startInfo = [Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            # PowerShell initializes its readonly HOME from USERPROFILE on
            # Windows. An environment HOME alone leaves the real private root
            # in scope there, so isolate the profile before the child starts.
            $profileVariable = if ($IsWindows) { 'USERPROFILE' } else { 'HOME' }
            $startInfo.Environment[$profileVariable] = $Scratch.Home
            if ($NoRuntime) { $null = $startInfo.Environment.Remove('YURUNA_RUNTIME_DIR') }
            else { $startInfo.Environment['YURUNA_RUNTIME_DIR'] = $Scratch.Runtime }
            $startInfo.Environment['YURUNA_LOG_DIR'] = $Scratch.Log
            $startInfo.Environment['YURUNA_NONINTERACTIVE'] = '1'
            $startInfo.Environment['YURUNA_HOST_ID_MODE'] = 'random'
            $startInfo.Environment['PATH'] = (Split-Path -Parent $script:Pwsh) + [IO.Path]::PathSeparator + $startInfo.Environment['PATH']
            foreach ($token in @('-NoProfile', '-NonInteractive', '-File', $script:ServicePath) + $Argument) {
                $startInfo.ArgumentList.Add($token)
            }
            $child = [Diagnostics.Process]::Start($startInfo)
            try {
                $stdout = $child.StandardOutput.ReadToEndAsync()
                $stderr = $child.StandardError.ReadToEndAsync()
                if (-not $child.WaitForExit(60000)) {
                    $child.Kill()
                    throw 'The refresh-safe child exceeded its test deadline.'
                }
                $drained = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).Wait(3000)
                $output = if ($drained) { $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
                    else { 'A descendant retained a redirected output handle after the launcher exited.' }
                $code = $child.ExitCode
            } finally { $child.Dispose() }
            $result = if (Test-Path -LiteralPath $Scratch.Result) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Scratch.Result)) } else { $null }
            return [pscustomobject]@{ ExitCode = $code; Result = $result; Output = ($output -replace "`e\[[0-9;]*[A-Za-z]", '') }
        }

        function Get-RefreshSafeArgument {
            [CmdletBinding()]
            [OutputType([string[]])]
            param([Parameter(Mandatory)]$Scratch, [Parameter(Mandatory)][int]$Port, [long]$DeadlineMs = 20000)
            return [string[]]@('-RefreshSafe', '-Port', "$Port", '-ResultPath', $Scratch.Result, '-DeadlineTickMs', "$([Environment]::TickCount64 + $DeadlineMs)")
        }
    }

    It 'reports a port another process holds as port-conflict and leaves that process and every control file alone' {
        $scratch = New-RefreshSafeScratch
        $port = Get-FreePort
        $holder = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
        try {
            $holder.ExclusiveAddressUse = $true
            $holder.Start()
            $before = Get-RuntimeSnapshot -Scratch $scratch
            $run = Invoke-RefreshSafeStart -Scratch $scratch -Argument (Get-RefreshSafeArgument -Scratch $scratch -Port $port)
            Assert-Equal 2 $run.ExitCode "unexpected exit: $($run.Output)"
            $expectedOutcome = if ($IsWindows -and $run.Result.outcome -eq 'port-privilege-required') { 'port-privilege-required' } else { 'port-conflict' }
            Assert-StringEqual $expectedOutcome $run.Result.outcome
            Assert-Equal 1 $run.Result.schemaVersion
            Assert-Equal $port $run.Result.port
            # Exercise the original listener: PowerShell/.NET on Linux and
            # macOS can return null for Server after ExclusiveAddressUse.
            Assert-Equal $port $holder.LocalEndpoint.Port 'the original listener still owns its endpoint'
            $connection = [System.Net.Sockets.TcpClient]::new()
            $accepted = $null
            try {
                Assert-True ($connection.ConnectAsync('127.0.0.1', $port).Wait(3000)) 'the original port still accepts connections'
                $accept = $holder.AcceptTcpClientAsync()
                Assert-True ($accept.Wait(3000)) 'the original listener was not disturbed'
                $accepted = $accept.GetAwaiter().GetResult()
            } finally {
                if ($accepted) { $accepted.Dispose() }
                $connection.Dispose()
            }
            $after = Get-RuntimeSnapshot -Scratch $scratch
            $findings = @()
            foreach ($name in $before.Keys) { if ($before[$name] -cne $after[$name]) { $findings += "$name changed" } }
            foreach ($name in $after.Keys) { if (-not $before.ContainsKey($name)) { $findings += "$name was written" } }
            Assert-NoFinding $findings 'the refresh-safe start changed the runtime directory'
        } finally {
            try { $holder.Stop() } catch { $null = $_ }
            Remove-YurunaTestTempDir $scratch.Root
        }
    }

    It 'leaves an owned server that answers running and reports existing-ready' {
        $scratch = New-RefreshSafeScratch
        $port = Get-FreePort
        $standIn = $null
        try {
            $serverScript = Join-Path $scratch.Runtime '.status-service.ps1'
            [IO.File]::WriteAllText($serverScript, @"
`$listener = [System.Net.HttpListener]::new()
`$listener.Prefixes.Add('http://localhost:$port/')
`$listener.Start()
while (`$listener.IsListening) {
    `$context = `$listener.GetContext()
    `$bytes = [System.Text.Encoding]::UTF8.GetBytes('ok')
    `$context.Response.ContentLength64 = `$bytes.Length
    `$context.Response.OutputStream.Write(`$bytes, 0, `$bytes.Length)
    `$context.Response.OutputStream.Close()
}
"@)
            $startOptions = @{ FilePath = $script:Pwsh; ArgumentList = @('-NoProfile', '-NonInteractive', '-File', ('"' + $serverScript + '"')); PassThru = $true }
            if ($IsWindows) { $startOptions.WindowStyle = 'Hidden' }
            $standIn = Start-Process @startOptions
            $ready = $false
            for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
                try { $null = Invoke-WebRequest -Uri "http://localhost:$port/status/" -TimeoutSec 1 -UseBasicParsing; $ready = $true } catch { Start-Sleep -Milliseconds 250 }
            }
            Assert-True $ready 'the stand-in server never answered'
            [IO.File]::WriteAllText((Join-Path $scratch.Runtime 'server.pid'), [string]$standIn.Id)
            $before = Get-RuntimeSnapshot -Scratch $scratch
            $run = Invoke-RefreshSafeStart -Scratch $scratch -Argument (Get-RefreshSafeArgument -Scratch $scratch -Port $port)
            Assert-Equal 0 $run.ExitCode "unexpected exit: $($run.Output)"
            Assert-StringEqual 'existing-ready' $run.Result.outcome
            Assert-StringEqual 'command-line' $run.Result.reason 'the process-identity classifier ran and the command line confirmed the owner'
            Assert-Equal $standIn.Id $run.Result.pid
            Assert-False $standIn.HasExited 'the answering server was left running'
            $after = Get-RuntimeSnapshot -Scratch $scratch
            Assert-StringEqual $before['server.pid'] $after['server.pid'] 'the pidfile is untouched'
            Assert-StringEqual $before['control.cycle-pause'] $after['control.cycle-pause']
            Assert-StringEqual $before['break-active.json'] $after['break-active.json'] 'the break sidecar a held runner needs survives'
        } finally {
            if ($standIn -and -not $standIn.HasExited) { try { $standIn.Kill() } catch { $null = $_ } }
            Remove-YurunaTestTempDir $scratch.Root
        }
    }

    It 'reports a pidfile it cannot identify as unknown-owner' {
        $scratch = New-RefreshSafeScratch
        try {
            [IO.File]::WriteAllText((Join-Path $scratch.Runtime 'server.pid'), 'garbage')
            $run = Invoke-RefreshSafeStart -Scratch $scratch -Argument (Get-RefreshSafeArgument -Scratch $scratch -Port (Get-FreePort))
            Assert-Equal 2 $run.ExitCode "unexpected exit: $($run.Output)"
            Assert-StringEqual 'unknown-owner' $run.Result.outcome
            Assert-StringEqual 'garbage' ([IO.File]::ReadAllText((Join-Path $scratch.Runtime 'server.pid'))) 'an unidentified pidfile is never removed'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'starts the real listener when binding is permitted and preserves controls across a second start' {
        $scratch = New-RefreshSafeScratch
        $port = Get-FreePort
        $listenerProcess = $null
        $beaconLock = $null
        try {
            $before = Get-RuntimeSnapshot -Scratch $scratch
            # The listener is real; the held scratch lock only prevents its
            # address beacon from announcing this temporary port to a pool.
            $beaconLock = [IO.File]::Open((Join-Path $scratch.Runtime 'hostaddress.beacon.lock'),
                [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $run = Invoke-RefreshSafeStart -Scratch $scratch -Argument (Get-RefreshSafeArgument -Scratch $scratch -Port $port -DeadlineMs 45000)
            if ($run.Result.outcome -eq 'port-privilege-required') {
                Assert-True $IsWindows 'wildcard URL reservations are a Windows privilege boundary'
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                try {
                    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
                    Assert-False ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'the elevated native canary must start the real listener'
                } finally { $identity.Dispose() }
                Assert-Equal 2 $run.ExitCode
                Assert-False (Test-Path -LiteralPath (Join-Path $scratch.Runtime 'server.pid')) 'a refused bind starts no listener'
            } else {
                Assert-Equal 0 $run.ExitCode "unexpected exit: $($run.Output)"
                Assert-StringEqual 'started' $run.Result.outcome
                $listenerProcess = Get-Process -Id $run.Result.pid -ErrorAction Stop
                # Native start-time sources can round differently on Linux;
                # use the same two-second window as the ownership classifier.
                $liveStart = [DateTimeOffset]::new($listenerProcess.StartTime).ToUnixTimeMilliseconds()
                Assert-True ([Math]::Abs([long]$run.Result.startTimeUnixMs - $liveStart) -le 2000) 'the result identifies the listener start'
                $status = Invoke-RestMethod -Uri "http://localhost:$port/runtime/status.json" -TimeoutSec 5
                Assert-StringEqual 'running' $status.overallStatus
                Assert-True $status.cyclePaused
                $control = Invoke-RestMethod -Uri "http://localhost:$port/control/control-status" -TimeoutSec 5
                Assert-NotNull $control.refresh 'the generated listener serves the refresh capability'
                [IO.File]::WriteAllText((Join-Path $scratch.Runtime 'server.sha'), 'older-checkout')
                $again = Invoke-RefreshSafeStart -Scratch $scratch -Argument (Get-RefreshSafeArgument -Scratch $scratch -Port $port)
                Assert-Equal 0 $again.ExitCode "unexpected second exit: $($again.Output)"
                Assert-StringEqual 'existing-ready' $again.Result.outcome
                Assert-Equal $listenerProcess.Id $again.Result.pid 'a changed commit never replaces the live listener'
                Assert-False $again.Result.shaMatches
                Assert-False $listenerProcess.HasExited
            }
            Assert-True (Test-Path -LiteralPath (Join-Path $scratch.Home '.yuruna/host-refresh')) 'startup admission belongs to the isolated child profile'
            foreach ($name in $before.Keys) {
                Assert-StringEqual $before[$name] ([IO.File]::ReadAllText((Join-Path $scratch.Runtime $name))) "$name survives a real listener start"
            }
        } finally {
            if ($listenerProcess) { $listenerProcess.Dispose(); $listenerProcess = $null }
            # A failed outcome assertion must still release a listener that
            # started. Trust the scratch pidfile only after its live command
            # line and start time identify this test's generated script.
            $ownership = Get-StatusServerOwnership -PidFile (Join-Path $scratch.Runtime 'server.pid') `
                -ExpectedScriptPath (Join-Path $scratch.Runtime '.status-service.ps1')
            if ($ownership.State -eq 'AliveOwned' -and $ownership.Reason -eq 'command-line') {
                $candidate = Get-Process -Id $ownership.Pid -ErrorAction SilentlyContinue
                # Keep cleanup consistent with the classifier's native
                # start-time tolerance so rounding cannot leak the listener.
                if ($candidate -and [Math]::Abs([DateTimeOffset]::new($candidate.StartTime).ToUnixTimeMilliseconds() - [long]$ownership.StartTimeUnixMs) -le 2000) {
                    $listenerProcess = $candidate
                } elseif ($candidate) { $candidate.Dispose() }
            }
            if ($listenerProcess -and -not $listenerProcess.HasExited) {
                $listenerProcess.Kill()
                $null = $listenerProcess.WaitForExit(10000)
            }
            if ($listenerProcess) { $listenerProcess.Dispose() }
            if ($beaconLock) { $beaconLock.Dispose() }
            Remove-YurunaTestTempDir $scratch.Root
        }
    }

    It 'refuses with admission-busy while another start holds the startup lock' {
        $scratch = New-RefreshSafeScratch
        $held = $null
        try {
            $lockName = 'status-service.{0}.start.lock' -f (Get-StatusRuntimeKey -RuntimeDir $scratch.Runtime)
            $lockPath = Get-YurunaPrivateStatePath -Name $lockName -HomePath $scratch.Home
            Assert-True $lockPath.Resolved "the scratch private root did not resolve: $($lockPath.Reason)"
            $held = Enter-YurunaSingleFlightLock -Path $lockPath.Path
            Assert-True $held.Held "the test could not take the startup lock: $($held.Reason)"
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-RefreshSafeStart -Scratch $scratch -Argument (Get-RefreshSafeArgument -Scratch $scratch -Port (Get-FreePort))
            $watch.Stop()
            Assert-Equal 2 $run.ExitCode "unexpected exit: $($run.Output)"
            Assert-StringEqual 'admission-busy' $run.Result.outcome
            Assert-StringEqual 'held-elsewhere' $run.Result.reason
        } finally {
            if ($held) { Exit-YurunaSingleFlightLock -Lock $held }
            Remove-YurunaTestTempDir $scratch.Root
        }
    }

    It 'refuses a result path inside a served directory and writes nothing there' {
        $scratch = New-RefreshSafeScratch
        try {
            $inside = Join-Path $scratch.Runtime 'result.json'
            $run = Invoke-RefreshSafeStart -Scratch $scratch -Argument @('-RefreshSafe', '-Port', "$(Get-FreePort)", '-ResultPath', $inside)
            Assert-Equal 1 $run.ExitCode "unexpected exit: $($run.Output)"
            Assert-False (Test-Path -LiteralPath $inside) 'no result is written into the served runtime directory'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'refuses without an owning runtime directory, and says so in its result' {
        $scratch = New-RefreshSafeScratch
        try {
            $run = Invoke-RefreshSafeStart -Scratch $scratch -NoRuntime -Argument (Get-RefreshSafeArgument -Scratch $scratch -Port (Get-FreePort))
            Assert-Equal 1 $run.ExitCode "unexpected exit: $($run.Output)"
            Assert-StringEqual 'invalid-invocation' $run.Result.outcome
            Assert-StringEqual 'runtime-unresolved' $run.Result.reason
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'refuses -RefreshSafe with -Restart, and an unknown switch, as binding errors' {
        $scratch = New-RefreshSafeScratch
        try {
            $both = Invoke-RefreshSafeStart -Scratch $scratch -Argument @('-RefreshSafe', '-Restart', '-Port', '1')
            Assert-NotEqual 0 $both.ExitCode
            Assert-Match 'Parameter set cannot be resolved|AmbiguousParameterSet' $both.Output
            $unknown = Invoke-RefreshSafeStart -Scratch $scratch -Argument @('-RefreshSafe', '-Port', '1', '-Bogus')
            Assert-NotEqual 0 $unknown.ExitCode
            Assert-Match 'A parameter cannot be found|NamedParameterNotFound' $unknown.Output
            Assert-Null $unknown.Result 'a refused binding runs nothing'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }
}
