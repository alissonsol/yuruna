<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42a24e8a-bb70-4de1-b78f-9bbdd82d9ea7
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

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path

Import-Module (Join-Path $here 'Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.Prelude.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.ServiceVm.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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

$StashScriptPath = Join-Path $repoRoot 'test/service/Start-StashServiceVM.ps1'
$script:StashSource     = Get-Content -Raw -LiteralPath $StashScriptPath
$script:SetupSource     = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'install/setup.ps1')

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
$script:TimedOutEndpoint = [pscustomobject]@{
    Ready = $false; Address = ''; WaitedSeconds = 2700; Unreachable = $false
    ListeningInGuest = $false; StillBuilding = $false; CloudInitStatus = ''
    LastProgress = ''; ExtendedSeconds = 0; AddressChanges = 0
    ObservedState = 'no guest address discovered yet, so nothing has been probed'
}
$script:BuildingEndpoint = [pscustomobject]@{
    Ready = $false; Address = '10.0.0.5'; WaitedSeconds = 5400; Unreachable = $false
    ListeningInGuest = $false; StillBuilding = $true; CloudInitStatus = 'running'
    LastProgress = 'Setting up golang-1.26-go'; ExtendedSeconds = 2700; AddressChanges = 0
}
$script:UnreachableEndpoint = [pscustomobject]@{
    Ready = $false; Address = '10.0.0.5'; WaitedSeconds = 300; Unreachable = $true
    ListeningInGuest = $true; StillBuilding = $false; CloudInitStatus = 'done'
    LastProgress = ''; ExtendedSeconds = 0; AddressChanges = 0
}
$script:ReadyEndpoint = [pscustomobject]@{
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
$script:SilentGuest = Invoke-SilentGuestWait
# The same silent guest, reached the way a macOS Shared-NAT host reaches it: the
# caller seeds the address the hypervisor gave, and the per-poll lookup answers
# nothing (Get-GuestAddress falling back to the VM name is exactly this).
$script:SeededGuest = Invoke-SilentGuestWait -SeedAddress '10.44.7.9' -ResolveAddress { '' }

}

Describe 'A readiness timeout is a failure, not a pass' {

    It 'fails when the budget ran out with the daemon unbound and the guest silent' {
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $script:TimedOutEndpoint
        Assert-StringEqual -Expected 'NotServing' -Actual $verdict.Outcome
        Assert-True $verdict.IsFailure 'a run that records PASS here reports a service that does not exist.'
    }

    It 'fails when the readiness wait never ran at all' {
        # A verdict that was never taken is not a pass: nothing confirmed the
        # daemon, so nothing may claim it.
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $null
        Assert-StringEqual -Expected 'NotServing' -Actual $verdict.Outcome
        Assert-True $verdict.IsFailure 'skipping the check is not evidence the daemon is up.'
    }

    It 'does NOT fail when the guest confirmed the daemon is bound' {
        # The service is running and reaches the pool through its own announce;
        # only this host's direct path is missing.
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $script:UnreachableEndpoint
        Assert-StringEqual -Expected 'Unreachable' -Actual $verdict.Outcome
        Assert-True (-not $verdict.IsFailure) 'a local networking gap is not a failed bring-up.'
    }

    It 'does NOT fail while the guest reports cloud-init is still running' {
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $script:BuildingEndpoint
        Assert-StringEqual -Expected 'StillBuilding' -Actual $verdict.Outcome
        Assert-True (-not $verdict.IsFailure) 'the build finishes on its own; "not yet" is not "broken".'
    }

    It 'passes when the daemon answered' {
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $script:ReadyEndpoint
        Assert-StringEqual -Expected 'Ready' -Actual $verdict.Outcome
        Assert-True (-not $verdict.IsFailure)
    }

    It 'routes the failure to a NON-ZERO exit code' {
        Assert-True ((Get-EntryPointExitCode -Outcome Failure) -ne 0) 'the installer reads the exit code and nothing else.'
        Assert-StringEqual -Expected 0 -Actual (Get-EntryPointExitCode -Outcome Ok)
    }
}

Describe 'Start-StashServiceVM reports the verdict it reached' {

    It 'exits with the failure code on the readiness-failure path' {
        $failBanner = $script:StashSource.IndexOf('== stash-service start: FAILED')
        Assert-True ($failBanner -ge 0) 'the failing path must announce itself as failed.'
        $exitFail = $script:StashSource.IndexOf('exit $ExitFailure', $failBanner)
        Assert-True ($exitFail -gt $failBanner) 'the failing path must end in a failure exit.'
    }

    It 'prints no "complete" banner on any path that did not complete' {
        # Matched on the prefix, not the whole banner: the suffix carries the VM
        # name and host, which is what an operator needs when several service VMs
        # are being brought up. The invariant is ONE completion banner on ONE
        # path, not its exact wording.
        $complete = $script:StashSource.IndexOf('== stash-service start: complete')
        Assert-True ($complete -ge 0) 'a successful bring-up still says so.'
        Assert-StringEqual -Expected 1 -Actual ([regex]::Matches($script:StashSource, [regex]::Escape('== stash-service start: complete')).Count) `
            'one banner, on one path -- a second copy is how a failing path grows one.'

        $failBanner = $script:StashSource.IndexOf('== stash-service start: FAILED')
        $exitOnFail = $script:StashSource.IndexOf('exit $ExitFailure', $failBanner)
        Assert-True ($exitOnFail -lt $complete) 'the failing path must leave before the banner it must not print.'

        $buildBanner = $script:StashSource.IndexOf('== stash-service start: STILL BUILDING')
        Assert-True ($buildBanner -ge 0) 'a guest that is still compiling gets its own banner, not "complete".'
        $exitOnBuilding = $script:StashSource.IndexOf('exit $ExitOk', $buildBanner)
        Assert-True ($exitOnBuilding -gt $buildBanner -and $exitOnBuilding -lt $complete) `
            'still-building is a success whose service is not up; it must not claim completion.'
    }

    It 'never hardcodes a zero exit' {
        $bare = [regex]::Matches($script:StashSource, '(?m)^\s*exit\s+0\s*$').Count
        Assert-StringEqual -Expected 0 -Actual $bare 'the outcome-to-code mapping is centralized so it can be changed in one place.'
    }

    It 'hands its ssh guidance through the formatter rather than interpolating an address' {
        # The shape that produced `ssh stash-admin@ '...'`: an address dropped
        # straight into the message, with nothing checking it exists.
        Assert-True ($script:StashSource -notmatch "ssh stash-admin@\`$") `
            'an address interpolated without a check is how an unrunnable command reaches the operator.'
        Assert-True ($script:StashSource -match 'Format-GuestSshDiagnosticHint') 'the formatter is what refuses to print a hole.'
    }

    It 'captures the guest console before failing' {
        # A frame showing a failed cifs mount answers instantly what a host-side
        # probe can only report as silence.
        Assert-True ($script:StashSource -match 'Get-VMScreenshot') 'on a readiness timeout the console is the remaining evidence.'
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
        Assert-True ($script:SilentGuest.Lines -match 'waiting for the stash-service daemon') 'the line must still show the wait is alive.'
        Assert-True ($script:SilentGuest.Lines -notmatch '(?i)building') 'nothing observed the guest building, so nothing may say it is.'
        Assert-True ($script:SilentGuest.Lines -match 'not accepting :22') 'what WAS observed is that the guest answers nothing.'
    }

    It 'keeps naming the address it is actually probing when discovery goes quiet' {
        # The caller seeds the address the hypervisor reported and the per-poll
        # lookup then answers nothing. The wait goes right on probing the seed,
        # so a line reading "nothing has been probed" is the same unmeasured
        # claim as a fixed label, merely inverted -- and a line that forgets and
        # re-learns the address changes text every poll, which floods the log.
        Assert-True ($script:SeededGuest.Lines -notmatch 'no guest address') 'a probe IS running, against an address this host holds.'
        Assert-True ($script:SeededGuest.Lines -match '10\.44\.7\.9') 'name the address the probe is aimed at.'
        Assert-True ($script:SeededGuest.Lines -match 'not accepting :22') 'the seeded address is probed, so reachability is measurable.'
        Assert-StringEqual -Expected '10.44.7.9' -Actual $script:SeededGuest.Record.Address 'the seed is what the wait carried out.'
        Assert-StringEqual -Expected 'unreachable' -Actual $script:SeededGuest.Record.Reachability `
            'reachability is the only thing separating "guest up, daemon not ready" from "guest answering nothing".'
    }

    It 'carries the final observation out with the verdict' {
        Assert-True ($script:SilentGuest.Record.ObservedState -match 'not accepting') 'the failure message quotes the last thing measured.'
        $verdict = Get-ServiceVmReadinessVerdict -Endpoint $script:SilentGuest.Record
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
        Assert-StringEqual -Expected "ssh stash-admin@192.168.7.234 'sudo tail -n 120 /var/log/cloud-init-output.log'" -Actual $hint
    }

    It 'sends the in-guest capture to the address it just located' {
        # Locating the guest and then dialing the NAME whose lookup already came
        # back empty throws away the only thing that found it -- and leaves the
        # operator with the console frame as the sole evidence when a full
        # in-guest capture was available.
        Assert-True ($script:StashSource -match 'Invoke-GuestSsh -VMName \$stashSshTarget') 'the capture goes to the address that was found.'
        Assert-True ($script:StashSource -match '\$stashSshTarget\s*=\s*if \(\$stashDiagIp\)') 'the VM name is the fallback, not the first choice.'
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
            Assert-StringEqual -Expected 'running' -Actual $r.Outcome
            Assert-StringEqual -Expected 0 -Actual $FakeVm.IpCalls 'the sweep stays one state query per service.'
        } finally { Uninstall-FakeVMDriver }
    }

    It 'reports a running VM whose port is silent as NOT healthy' {
        # Port 9 discard is closed on the loopback of every host this runs on, so
        # the connect is refused rather than filtered -- a fast, definite no.
        Install-FakeVMDriver -State 'running' -Address '127.0.0.1'
        try {
            $r = @(Restore-YurunaServiceVM -Key 'stash' -ProbeRunning -Confirm:$false) | Select-Object -First 1
            Assert-StringEqual -Expected 'running' -Actual $r.Outcome 'the state reading is unchanged; only the verdict about it is new.'
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
        Assert-True ($script:SetupSource -match 'Restore-YurunaServiceVM -Key @\(\$RosterKey\) -ProbeRunning') `
            'the reuse check has to ask for the probe; without it the record says healthy on state alone.'
        $running = $script:SetupSource.IndexOf("'running'  {")
        Assert-True ($running -ge 0) 'the reuse verdict still branches on the running outcome.'
        $adopt = $script:SetupSource.IndexOf('Adopt = $true', $running)
        $gate  = $script:SetupSource.IndexOf('if ($r.Healthy)', $running)
        Assert-True ($gate -ge 0 -and $gate -lt $adopt) 'adoption of a running VM must sit behind the health verdict.'
    }

    It 'publishes stash readiness only after the common verdict' {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:StashSource, [ref]$null, [ref]$errors)
        Assert-Equal -Expected 0 -Actual @($errors).Count -Because 'the stash launcher must parse'
        $writes = @($ast.FindAll({ param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Write-ExtensionServiceMarker'
                }, $true))
        Assert-Equal -Expected 1 -Actual $writes.Count -Because 'one readiness decision must produce one marker write'
        $assignments = @($ast.FindAll({ param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$stashDaemonReady'
                }, $true))
        Assert-Equal -Expected 1 -Actual $assignments.Count -Because 'the advertised state must be assigned from the verdict'
        Assert-True ($assignments[0].Right.Extent.Text -match [regex]::Escape("`$stashVerdict.Outcome -in @('Ready', 'Unreachable')")) `
            'a still-building guest is not an active service'
        Assert-True ($assignments[0].Extent.EndOffset -lt $writes[0].Extent.StartOffset) 'readiness must precede the advertisement'
        Assert-True ($writes[0].Extent.Text -match '-Active \$stashDaemonReady') 'the marker must carry the readiness decision'
        Assert-True ($script:StashSource -match "if \(\`$runtimeDir -and \`$stashVerdict.Outcome -eq 'Ready'\)") `
            'only a daemon reachable from the host may publish a URL'
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
        Assert-StringEqual -Expected 1 -Actual $emitted.Count 'the state did not change, so the clock alone earns nothing.'
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
        Assert-StringEqual -Expected 2 -Actual $emitted.Count 'a change in what is being reported is exactly what a log entry is for.'
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
        Assert-StringEqual -Expected 2 -Actual $emitted.Count 'a new wait is a new line, whatever the previous one last said.'
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

Describe 'the readiness wait reports what the guest actually said' {

    It 'skips decorative lines when picking the last cloud-init step' {
        # A bare `tail -n 1` reports whatever was printed last. cloud-init ends
        # by generating host keys, so a FAILED build showed the operator the top
        # border of an SSH randomart box -- "+----[SHA256]-----+" -- for the
        # whole wait, while the real error sat a few lines above it.
        $here     = Split-Path -Parent $PSCommandPath
        $repoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
        $src      = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.VMUtility.psm1')
        $probe    = [regex]::Match($src, 'YURUNA_PROGRESS=[^\n]*(\n[^\n]*){0,6}')
        Assert-True $probe.Success 'the in-guest progress probe must exist'
        Assert-True ($probe.Value -notmatch 'tail -n 1 /var/log') `
            'taking only the final line is what reported randomart instead of the error'
        Assert-Match -Pattern 'grep -vE' -Actual $probe.Value `
            -Because 'blank and box-drawing lines must be filtered before the last line is taken'
    }

    It 'ends the wait when cloud-init has errored rather than serving out the budget' {
        # Nothing re-runs cloud-init on this boot, so every further poll asks a
        # question already answered. The observed cost was 45 minutes of progress
        # bar after the guest had reported ERRORED at minute two.
        $here     = Split-Path -Parent $PSCommandPath
        $repoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
        $src      = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.VMUtility.psm1')
        Assert-Match -Pattern "cloudInitStatus -match '\^error\$'" -Actual $src `
            -Because 'a terminal cloud-init error must end the wait'
        $errBranch = $src.IndexOf("cloudInitStatus -match '^error$'")
        $nextBreak = $src.IndexOf('break', $errBranch)
        Assert-True (($nextBreak -gt $errBranch) -and (($nextBreak - $errBranch) -lt 600)) `
            'the error branch must leave the poll loop, not merely log'
    }

    It 'keeps waiting on done, where the daemon may still be binding' {
        # The distinction that makes the early exit safe: cloud-init finishing is
        # not the daemon having failed, so 'done' must NOT short-circuit.
        $here     = Split-Path -Parent $PSCommandPath
        $repoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
        $src      = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.VMUtility.psm1')
        Assert-True ($src -notmatch "cloudInitStatus -match '\^\(error\|done\)") `
            'done must not be treated as terminal'
    }
}
