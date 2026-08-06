<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42d7c1e9-8b04-4a3f-9c62-7e15b0d4a933
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service readiness verdict progress diagnostics pester
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
    A service VM whose daemon never started must be reported as a failure, with
    progress and diagnostics that describe what was observed.
.DESCRIPTION
    WHY THIS RULE EXISTS. A bring-up script's exit code is what the installer
    records as the step's outcome. A script that warns "the daemon did not come
    up" and then exits 0 puts a PASS in the run summary for a service that does
    not exist, and the operator spends the next failure looking in the wrong
    layer. Waiting and then passing anyway is strictly worse than not waiting:
    the wait produced the evidence and then discarded it.

    Not every non-serving outcome is a failure, and the difference is always
    evidence the guest supplied -- it confirmed the daemon is bound, or it
    confirmed cloud-init is still running. Absent that evidence, a timeout is a
    failure. Those three cases and their exit codes are what this file pins.

    Two supporting rules are pinned with them, because both are ways the same
    wait lied about a guest it never asked:
      * the progress line may state only what was measured. A fixed "building
        the daemon" label reads identically whether the guest is compiling or
        idling at a login prompt with cloud-init dead, and the operator waits
        out the whole budget believing the first;
      * a diagnostic command must be runnable. Interpolating an address that
        was never resolved yields `ssh user@ '...'`, which cannot be run and
        hides the fact that is actually blocking the reader.

    Assertions are plain throws and the Pester harness is shimmed when Pester is
    absent, so this runs either way.
    Run: pwsh -NoProfile -File test/modules/Test.ServiceVmReadiness.Tests.ps1
         (or Invoke-Pester -Path test/modules/Test.ServiceVmReadiness.Tests.ps1)
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path

Import-Module (Join-Path $here 'Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.Prelude.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.ServiceVm.psm1') -Force -DisableNameChecking

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ("$Expected" -ne "$Actual") { throw "Expected [$Expected] got [$Actual]. $Because" } }

# Pester is not installed on every host that runs this repo's scripts, and the
# assertions here are plain throws, so the harness the file needs is three
# functions. Defined only when the real ones are absent; every fixture is
# computed at file scope, so the immediate-run shim and Pester's
# discovery-then-run split observe the same state.
if (-not (Get-Command -Name 'Describe' -ErrorAction SilentlyContinue)) {
    function Describe { param([string]$Name, [scriptblock]$Fixture) Write-Output "Describe: $Name"; & $Fixture }
    function Context  { param([string]$Name, [scriptblock]$Fixture) Write-Output "  Context: $Name"; & $Fixture }
    function It       { param([string]$Name, [scriptblock]$Test)    & $Test; Write-Output "    [pass] $Name" }
}

$StashScriptPath = Join-Path $repoRoot 'test/Start-StashServiceVM.ps1'
$StashSource     = Get-Content -Raw -LiteralPath $StashScriptPath
$SetupSource     = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'install/setup.ps1')

# Stands in for the per-host VM driver. Restore-YurunaServiceVM resolves these by
# NAME at call time, so a definition in the global scope is what it finds -- the
# same mechanism that lets it degrade to a reported no-op on a host where the
# driver never loaded. The shared record is what makes "did anyone even ask for
# an address?" observable, which is the difference between the sweep's cheap
# default and the probing a reuse decision needs.
$FakeVm = @{ State = 'running'; Address = '127.0.0.1'; IpCalls = 0 }
function Install-FakeVMDriver {
    param([string]$State = 'running', [string]$Address = '127.0.0.1')
    $vm = $FakeVm
    $vm.State = $State; $vm.Address = $Address; $vm.IpCalls = 0
    # No param blocks: a simple function collects unmatched arguments in $args,
    # so these bind whatever the caller passes without restating the contract.
    Set-Item -Path 'function:global:Get-VMState' -Value ({ $vm.State }.GetNewClosure())
    Set-Item -Path 'function:global:Start-VM'    -Value { @{ success = $true } }
    Set-Item -Path 'function:global:Get-VMIp'    -Value ({ $vm.IpCalls++; $vm.Address }.GetNewClosure())
}
function Uninstall-FakeVMDriver {
    # 'Function:\<name>', NOT 'function:global:<name>'. Set-Item honors the scope
    # qualifier and Remove-Item silently ignores it, so the global: spelling
    # defines a stub and then fails to take it away -- leaving a fake hypervisor
    # standing for every later suite in the same runspace, which is how a shared
    # Pester run gets a passing service VM that does not exist.
    foreach ($name in @('Get-VMState', 'Start-VM', 'Get-VMIp')) {
        Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue
    }
}

# The two records a real wait returns at each end of the verdict: one that ran
# its whole budget against a guest that answered nothing, and one where the
# guest itself confirmed the build is still going.
$TimedOutEndpoint = [pscustomobject]@{
    Ready = $false; Address = ''; WaitedSeconds = 2700; Unreachable = $false
    ListeningInGuest = $false; StillBuilding = $false; CloudInitStatus = ''
    LastProgress = ''; ExtendedSeconds = 0; AddressChanges = 0
    ObservedState = 'no guest address discovered yet, so nothing has been probed'
}
$BuildingEndpoint = [pscustomobject]@{
    Ready = $false; Address = '10.0.0.5'; WaitedSeconds = 5400; Unreachable = $false
    ListeningInGuest = $false; StillBuilding = $true; CloudInitStatus = 'running'
    LastProgress = 'Setting up golang-1.26-go'; ExtendedSeconds = 2700; AddressChanges = 0
}
$UnreachableEndpoint = [pscustomobject]@{
    Ready = $false; Address = '10.0.0.5'; WaitedSeconds = 300; Unreachable = $true
    ListeningInGuest = $true; StillBuilding = $false; CloudInitStatus = 'done'
    LastProgress = ''; ExtendedSeconds = 0; AddressChanges = 0
}
$ReadyEndpoint = [pscustomobject]@{
    Ready = $true; Address = '10.0.0.5'; WaitedSeconds = 420; Unreachable = $false
    ListeningInGuest = $false; StillBuilding = $false; CloudInitStatus = 'done'
    LastProgress = ''; ExtendedSeconds = 0; AddressChanges = 0
}

# Drives a whole wait against a guest that answers nothing at all -- the case a
# fixed progress label describes as "building" for forty-five minutes. Returns
# the record plus every progress line that was emitted.
function Invoke-SilentGuestWait {
    param(
        [int]$Seconds = 3,
        [string]$SeedAddress = '',
        [scriptblock]$ResolveAddress = { '192.168.7.234' }
    )
    $savedNonInteractive = $env:YURUNA_NONINTERACTIVE
    try {
        # Forces the line-per-update path, which is the one a captured child
        # writes into a log -- and the only one whose text can be read back.
        $env:YURUNA_NONINTERACTIVE = '1'
        $emitted = Wait-YurunaServiceVmDaemon -VMName 'yuruna-stash-service' -Port 80 `
            -TimeoutSeconds $Seconds -MaxTimeoutSeconds $Seconds -PollSeconds 1 `
            -ReachabilityEverySeconds 1 -GuestKey 'guest.stash-service' -User 'stash-admin' `
            -ServiceLabel 'stash-service daemon' -InGuestCheckAfterSeconds 0 -InGuestCheckEverySeconds 1 `
            -Address $SeedAddress `
            -ResolveAddress $ResolveAddress -TestPortOpen { $false } -InvokeInGuest { $null } 6>&1
    } finally { $env:YURUNA_NONINTERACTIVE = $savedNonInteractive }
    $record = @($emitted | Where-Object { $_ -is [pscustomobject] }) | Select-Object -Last 1
    $lines  = @($emitted | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
        ForEach-Object { [string]$_.MessageData })
    return [pscustomobject]@{ Record = $record; Lines = ($lines -join "`n") }
}
$SilentGuest = Invoke-SilentGuestWait
# The same silent guest, reached the way a macOS Shared-NAT host reaches it: the
# caller seeds the address the hypervisor gave, and the per-poll lookup answers
# nothing (Get-GuestAddress falling back to the VM name is exactly this).
$SeededGuest = Invoke-SilentGuestWait -SeedAddress '10.44.7.9' -ResolveAddress { '' }

Describe 'A readiness timeout is a failure, not a pass' {

    It 'fails when the budget ran out with the daemon unbound and the guest silent' {
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $TimedOutEndpoint
        Assert-Equal -Expected 'NotServing' -Actual $verdict.Outcome
        Assert-True $verdict.IsFailure 'a run that records PASS here reports a service that does not exist.'
    }

    It 'fails when the readiness wait never ran at all' {
        # A verdict that was never taken is not a pass: nothing confirmed the
        # daemon, so nothing may claim it.
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $null
        Assert-Equal -Expected 'NotServing' -Actual $verdict.Outcome
        Assert-True $verdict.IsFailure 'skipping the check is not evidence the daemon is up.'
    }

    It 'does NOT fail when the guest confirmed the daemon is bound' {
        # The service is running and reaches the pool through its own announce;
        # only this host's direct path is missing.
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $UnreachableEndpoint
        Assert-Equal -Expected 'Unreachable' -Actual $verdict.Outcome
        Assert-True (-not $verdict.IsFailure) 'a local networking gap is not a failed bring-up.'
    }

    It 'does NOT fail while the guest reports cloud-init is still running' {
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $BuildingEndpoint
        Assert-Equal -Expected 'StillBuilding' -Actual $verdict.Outcome
        Assert-True (-not $verdict.IsFailure) 'the build finishes on its own; "not yet" is not "broken".'
    }

    It 'passes when the daemon answered' {
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $ReadyEndpoint
        Assert-Equal -Expected 'Ready' -Actual $verdict.Outcome
        Assert-True (-not $verdict.IsFailure)
    }

    It 'routes the failure to a NON-ZERO exit code' {
        Assert-True ((Get-EntryPointExitCode -Outcome Failure) -ne 0) 'the installer reads the exit code and nothing else.'
        Assert-Equal -Expected 0 -Actual (Get-EntryPointExitCode -Outcome Ok)
    }
}

Describe 'Start-StashServiceVM reports the verdict it reached' {

    It 'exits with the failure code on the readiness-failure path' {
        $failBanner = $StashSource.IndexOf('== stash-service start: FAILED')
        Assert-True ($failBanner -ge 0) 'the failing path must announce itself as failed.'
        $exitFail = $StashSource.IndexOf('exit $ExitFailure', $failBanner)
        Assert-True ($exitFail -gt $failBanner) 'the failing path must end in a failure exit.'
    }

    It 'prints no "complete" banner on any path that did not complete' {
        $complete = $StashSource.IndexOf('== stash-service start: complete ==')
        Assert-True ($complete -ge 0) 'a successful bring-up still says so.'
        Assert-Equal -Expected 1 -Actual ([regex]::Matches($StashSource, [regex]::Escape('== stash-service start: complete ==')).Count) `
            'one banner, on one path -- a second copy is how a failing path grows one.'

        $failBanner = $StashSource.IndexOf('== stash-service start: FAILED')
        $exitOnFail = $StashSource.IndexOf('exit $ExitFailure', $failBanner)
        Assert-True ($exitOnFail -lt $complete) 'the failing path must leave before the banner it must not print.'

        $buildBanner = $StashSource.IndexOf('== stash-service start: STILL BUILDING')
        Assert-True ($buildBanner -ge 0) 'a guest that is still compiling gets its own banner, not "complete".'
        $exitOnBuilding = $StashSource.IndexOf('exit $ExitOk', $buildBanner)
        Assert-True ($exitOnBuilding -gt $buildBanner -and $exitOnBuilding -lt $complete) `
            'still-building is a success whose service is not up; it must not claim completion.'
    }

    It 'never hardcodes a zero exit' {
        $bare = [regex]::Matches($StashSource, '(?m)^\s*exit\s+0\s*$').Count
        Assert-Equal -Expected 0 -Actual $bare 'the outcome-to-code mapping is centralized so it can be changed in one place.'
    }

    It 'hands its ssh guidance through the formatter rather than interpolating an address' {
        # The shape that produced `ssh stash-admin@ '...'`: an address dropped
        # straight into the message, with nothing checking it exists.
        Assert-True ($StashSource -notmatch "ssh stash-admin@\`$") `
            'an address interpolated without a check is how an unrunnable command reaches the operator.'
        Assert-True ($StashSource -match 'Format-GuestSshDiagnosticHint') 'the formatter is what refuses to print a hole.'
    }

    It 'captures the guest console before failing' {
        # A frame showing a failed cifs mount answers instantly what a host-side
        # probe can only report as silence.
        Assert-True ($StashSource -match 'Get-VMScreenshot') 'on a readiness timeout the console is the remaining evidence.'
    }
}

Describe 'The progress line states what was observed, never what was assumed' {

    It 'claims nothing about a guest whose address was never discovered' {
        $state = Get-ServiceVmObservedState -Address '' -Port 80
        Assert-True ($state -match 'no guest address') 'the honest report of nothing is "nothing".'
        Assert-True ($state -notmatch 'build') 'a claim about what the guest is doing needs a guest to have answered.'
    }

    It 'tells an unreachable guest apart from one that is merely not serving' {
        $down = Get-ServiceVmObservedState -Address '192.168.7.234' -Port 80 -ProbePort 22 -Reachability 'unreachable'
        $up   = Get-ServiceVmObservedState -Address '192.168.7.234' -Port 80 -ProbePort 22 -Reachability 'reachable'
        Assert-True ($down -match 'not accepting') 'a guest answering nothing is a boot or networking fault.'
        Assert-True ($up   -match 'accepts :22')   'a guest answering sshd is a daemon that is not ready yet.'
        Assert-True ($down -ne $up) 'the two need different actions, so they must not read the same.'
    }

    It 'quotes cloud-init instead of asserting a build' {
        $running  = Get-ServiceVmObservedState -Address '10.0.0.5' -CloudInitStatus 'running' -LastProgress 'Setting up golang-1.26-go'
        $finished = Get-ServiceVmObservedState -Address '10.0.0.5' -CloudInitStatus 'done'
        $errored  = Get-ServiceVmObservedState -Address '10.0.0.5' -CloudInitStatus 'error'
        Assert-True ($running  -match 'cloud-init is running')   'the guest said it; the line repeats it.'
        Assert-True ($running  -match 'golang-1\.26-go')         'the last step is what makes a long wait legible.'
        Assert-True ($finished -match 'FINISHED')                'cloud-init being over is the fact that turns a wait into a failure.'
        Assert-True ($errored  -match 'ERRORED')
    }

    It 'never says the guest is building when the guest never said so' {
        # A guest idle at a login prompt, answering neither :22 nor SSH, under a
        # progress line that asserts it is compiling: the operator reads the
        # claim, believes the build is progressing, and waits out the whole
        # budget on it.
        Assert-True ($SilentGuest.Lines -match 'waiting for the stash-service daemon') 'the line must still show the wait is alive.'
        Assert-True ($SilentGuest.Lines -notmatch '(?i)building') 'nothing observed the guest building, so nothing may say it is.'
        Assert-True ($SilentGuest.Lines -match 'not accepting :22') 'what WAS observed is that the guest answers nothing.'
    }

    It 'keeps naming the address it is actually probing when discovery goes quiet' {
        # The caller seeds the address the hypervisor reported and the per-poll
        # lookup then answers nothing. The wait goes right on probing the seed,
        # so a line reading "nothing has been probed" is the same unmeasured
        # claim as a fixed label, merely inverted -- and a line that forgets and
        # re-learns the address changes text every poll, which floods the log.
        Assert-True ($SeededGuest.Lines -notmatch 'no guest address') 'a probe IS running, against an address this host holds.'
        Assert-True ($SeededGuest.Lines -match '10\.44\.7\.9') 'name the address the probe is aimed at.'
        Assert-True ($SeededGuest.Lines -match 'not accepting :22') 'the seeded address is probed, so reachability is measurable.'
        Assert-Equal -Expected '10.44.7.9' -Actual $SeededGuest.Record.Address 'the seed is what the wait carried out.'
        Assert-Equal -Expected 'unreachable' -Actual $SeededGuest.Record.Reachability `
            'reachability is the only thing separating "guest up, daemon not ready" from "guest answering nothing".'
    }

    It 'carries the final observation out with the verdict' {
        Assert-True ($SilentGuest.Record.ObservedState -match 'not accepting') 'the failure message quotes the last thing measured.'
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $SilentGuest.Record
        Assert-True $verdict.IsFailure 'a guest that answered nothing for the whole budget is a failed bring-up.'
    }
}

Describe 'Diagnostics an operator can actually run' {

    It 'never emits an ssh command with an empty host' {
        foreach ($addr in @('', '   ', 'yuruna-stash-service')) {
            # The bare VM name is what address resolution falls back to when it
            # discovers nothing, so it is "unknown" too, not an address.
            $hint = Format-GuestSshDiagnosticHint -User 'stash-admin' -Address $addr -VMName 'yuruna-stash-service' -Command 'sudo tail -n 120 /var/log/cloud-init-output.log'
            Assert-True ($hint -notmatch "ssh stash-admin@\s") 'a command with a hole where the host goes is not a diagnostic.'
            Assert-True ($hint -notmatch "ssh stash-admin@'")  'nor is one that runs straight into the quoted command.'
            Assert-True ($hint -match 'never resolved an address') 'say what is actually blocking the reader.'
        }
    }

    It 'names how to find the address it could not resolve' {
        $hint = Format-GuestSshDiagnosticHint -User 'stash-admin' -Address '' -VMName 'yuruna-stash-service' -Command 'true'
        Assert-True ($hint -match 'ssh stash-admin@<the-address-you-found>') 'the reader still needs the shape of the command.'
        if ($IsMacOS) {
            Assert-True ($hint -match 'MacAddress') 'the bundle MAC is the guest identity that survives a rebuild.'
            Assert-True ($hint -match 'arp -an')    'and the ARP table is where it resolves to an address.'
        }
    }

    It 'gives a runnable command the moment an address is known' {
        $hint = Format-GuestSshDiagnosticHint -User 'stash-admin' -Address '192.168.7.234' -VMName 'yuruna-stash-service' -Command 'sudo tail -n 120 /var/log/cloud-init-output.log'
        Assert-Equal -Expected "ssh stash-admin@192.168.7.234 'sudo tail -n 120 /var/log/cloud-init-output.log'" -Actual $hint
    }

    It 'sends the in-guest capture to the address it just located' {
        # Locating the guest and then dialing the NAME whose lookup already came
        # back empty throws away the only thing that found it -- and leaves the
        # operator with the console frame as the sole evidence when a full
        # in-guest capture was available.
        Assert-True ($StashSource -match 'Invoke-GuestSsh -VMName \$stashSshTarget') 'the capture goes to the address that was found.'
        Assert-True ($StashSource -match '\$stashSshTarget\s*=\s*if \(\$stashDiagIp\)') 'the VM name is the fallback, not the first choice.'
    }

    It 'reuses the host driver for bundle-MAC discovery instead of a second copy' {
        $sshModule = Get-Content -Raw -LiteralPath (Join-Path $here 'Test.Ssh.psm1')
        Assert-True ($sshModule -match 'Resolve-UtmGuestIpByMac') 'the driver already matches a bundle MAC in the ARP table.'
        Assert-True ($sshModule -notmatch '/usr/sbin/arp') 'a second ARP parser here is a second thing to keep correct.'
    }
}

Describe 'A service that is merely powered on is not a service' {
    # The same false pass as a zero exit code, made one run later and by a
    # different route. A bring-up that fails leaves its guest RUNNING on purpose
    # -- the guest is the evidence, and the operator is told to stop it by hand
    # -- so the next run finds a registered, powered-on VM whose daemon never
    # existed. Reusing it on the state alone reports the service as fine and
    # never invokes the start script that would fail again.

    It 'does not ask for an address at all on the sweep path' {
        # The per-cycle reboot sweep only ever STARTS what is off. Probing there
        # would spend a lookup and a connect per service per cycle to answer a
        # question it does not ask, so the probe is opt-in and this pins that.
        Install-FakeVMDriver -State 'running'
        try {
            $r = @(Restore-YurunaServiceVM -Key 'stash' -Confirm:$false) | Select-Object -First 1
            Assert-Equal -Expected 'running' -Actual $r.Outcome
            Assert-Equal -Expected 0 -Actual $FakeVm.IpCalls 'the sweep stays one state query per service.'
        } finally { Uninstall-FakeVMDriver }
    }

    It 'reports a running VM whose port is silent as NOT healthy' {
        # Port 9 discard is closed on the loopback of every host this runs on, so
        # the connect is refused rather than filtered -- a fast, definite no.
        Install-FakeVMDriver -State 'running' -Address '127.0.0.1'
        try {
            $r = @(Restore-YurunaServiceVM -Key 'stash' -ProbeRunning -Confirm:$false) | Select-Object -First 1
            Assert-Equal -Expected 'running' -Actual $r.Outcome 'the state reading is unchanged; only the verdict about it is new.'
            Assert-True (-not $r.Healthy) 'powered on with nothing answering is not a running service.'
            Assert-True ($r.Message -match '80') 'the message has to name the port that did not answer.'
            Assert-True ($FakeVm.IpCalls -ge 1) 'the port cannot be probed without resolving where to probe it.'
        } finally { Uninstall-FakeVMDriver }
    }

    It 'reports a running VM whose port answers as healthy' {
        # Asserted so the rule above cannot be satisfied by never reporting a
        # running VM healthy, which would rebuild every service on every re-run.
        $listener = $null
        try {
            try {
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 3128)
                $listener.Start()
            } catch { $listener = $null }
            if (-not (Test-YurunaServiceVmPort -Address '127.0.0.1' -Port 3128)) {
                throw 'nothing could be made to answer 127.0.0.1:3128, so the healthy path was not exercised.'
            }
            Install-FakeVMDriver -State 'running' -Address '127.0.0.1'
            $r = @(Restore-YurunaServiceVM -Key 'caching-proxy' -ProbeRunning -Confirm:$false) | Select-Object -First 1
            Assert-True $r.Healthy 'a port that answers is the whole of the question.'
            Assert-True ($r.Message -match '3128') 'and the message says what answered.'
        } finally {
            Uninstall-FakeVMDriver
            if ($listener) { try { $listener.Stop() } catch { $null = $_ } }
        }
    }

    It 'refuses to call a VM healthy when no address could be resolved' {
        # Not a technicality: every consumer of a service reaches it by address,
        # so a service this host cannot name is one it cannot use either.
        Install-FakeVMDriver -State 'running' -Address ''
        try {
            $r = @(Restore-YurunaServiceVM -Key 'stash' -ProbeRunning -Confirm:$false) | Select-Object -First 1
            Assert-True (-not $r.Healthy) 'unprobed is not the same answer as answering.'
            Assert-True ($r.Message -match 'no address') 'say which half of the check could not be made.'
        } finally { Uninstall-FakeVMDriver }
    }

    It 'makes install/setup.ps1 probe before it reuses a service' {
        # Read from the source: a copy of the rule here would go on passing after
        # the reuse decision stopped applying it.
        Assert-True ($SetupSource -match 'Restore-YurunaServiceVM -Key @\(\$RosterKey\) -ProbeRunning') `
            'the reuse check has to ask for the probe; without it the record says healthy on state alone.'
        $running = $SetupSource.IndexOf("'running'  {")
        Assert-True ($running -ge 0) 'the reuse verdict still branches on the running outcome.'
        $adopt = $SetupSource.IndexOf('Adopt = $true', $running)
        $gate  = $SetupSource.IndexOf('if ($r.Healthy)', $running)
        Assert-True ($gate -ge 0 -and $gate -lt $adopt) 'adoption of a running VM must sit behind the health verdict.'
    }
}

Describe 'A wait that is throttled into a log still says what changed' {

    It 'collapses a line whose only change is the clock' {
        # What a 45-minute wait costs a log file. The message differs every poll
        # because it carries elapsed time, so throttling on the text alone
        # collapses nothing and several hundred near-identical entries land in
        # the file the operator has to read afterwards.
        $emitted = [System.Collections.Generic.List[string]]::new()
        $saved = $InformationPreference
        try {
            $InformationPreference = 'Continue'
            foreach ($tick in 3, 6, 9) {
                Write-YurunaWaitProgress -Message "00m${tick}s  waiting -- guest accepts :22" -Mode lines `
                    -RedirectedEverySeconds 300 -IdentityKey 'vm|1|guest accepts :22' 6>&1 |
                    ForEach-Object { $emitted.Add("$_") }
            }
        } finally { $InformationPreference = $saved }
        Assert-Equal -Expected 1 -Actual $emitted.Count 'the state did not change, so the clock alone earns nothing.'
    }

    It 'emits at once when the state behind the line changes' {
        # The other half: a throttle that collapsed everything would hide the one
        # transition the reader is waiting for.
        $emitted = [System.Collections.Generic.List[string]]::new()
        $saved = $InformationPreference
        try {
            $InformationPreference = 'Continue'
            Write-YurunaWaitProgress -Message '00m03s  waiting -- not accepting :22' -Mode lines `
                -RedirectedEverySeconds 300 -IdentityKey 'vm|1|not accepting :22' 6>&1 |
                ForEach-Object { $emitted.Add("$_") }
            Write-YurunaWaitProgress -Message '00m06s  waiting -- cloud-init is running' -Mode lines `
                -RedirectedEverySeconds 300 -IdentityKey 'vm|1|cloud-init is running' 6>&1 |
                ForEach-Object { $emitted.Add("$_") }
        } finally { $InformationPreference = $saved }
        Assert-Equal -Expected 2 -Actual $emitted.Count 'a change in what is being reported is exactly what a log entry is for.'
    }

    It 'does not silence a later wait that opens where an earlier one ended' {
        # The throttle state is module-scoped, because the console is. Two waits
        # in one process therefore share it, and the second would print nothing
        # for a full interval whenever its first observation matches the first
        # wait's last one -- which is the common case, since both start out
        # unable to reach the guest.
        $emitted = [System.Collections.Generic.List[string]]::new()
        $saved = $InformationPreference
        try {
            $InformationPreference = 'Continue'
            Write-YurunaWaitProgress -Message '05m00s  waiting -- not accepting :22' -Mode lines `
                -RedirectedEverySeconds 300 -IdentityKey 'vm|100|not accepting :22' 6>&1 |
                ForEach-Object { $emitted.Add("$_") }
            Write-YurunaWaitProgress -Message '00m03s  waiting -- not accepting :22' -Mode lines `
                -RedirectedEverySeconds 300 -IdentityKey 'vm|200|not accepting :22' 6>&1 |
                ForEach-Object { $emitted.Add("$_") }
        } finally { $InformationPreference = $saved }
        Assert-Equal -Expected 2 -Actual $emitted.Count 'a new wait is a new line, whatever the previous one last said.'
    }

    It 'is what the service-VM wait actually passes' {
        # Source-read rather than restated: the property is that the WAIT keeps
        # the clock out of its throttle identity, and a rule kept only here would
        # go on passing after the caller dropped it.
        $sshModule = Get-Content -Raw -LiteralPath (Join-Path $here 'Test.Ssh.psm1')
        Assert-True ($sshModule -match '-IdentityKey "\$\(\$o\.VMName\)\|\$\(\$o\.StartedAt\.Ticks\)') `
            'the observed state and the wait it belongs to are the identity; the clock is not.'
        $vmUtility = Get-Content -Raw -LiteralPath (Join-Path $here 'Test.VMUtility.psm1')
        Assert-True ($vmUtility -match '-IdentityKey "\$VMName\|\$\(\$probeStart\.Ticks\)') `
            'the wait''s own progress line carries the same guarantee for callers that use its label.'
    }
}
