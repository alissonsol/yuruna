<#PSScriptInfo
.VERSION 2026.09.27
.GUID 426638a9-3c83-4796-8371-fa8298592238
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos utm probe responsive tcc pester
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
    The macOS driver's Test-VirtualizationResponsive probe, its utmctl
    resolver, the Apple Event wording table, the GUI-session classifier, the
    start-if-stopped verb, and the driver's contract coverage.
.DESCRIPTION
    Every behavioral case drives the real driver against the stand-in macOS
    host from Test.MacUtmFakeHost (fake utmctl, pgrep, open, launchctl, ...
    on a private PATH), so the cases run -- and must pass -- on any POSIX
    host; nothing here is skipped for not being a Mac. Windows skips the
    shim-backed cases because the stand-ins are /bin/sh scripts, and says so.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:DriverPath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
    # Three drivers publish a module named Yuruna.Host; only this one may be
    # resident while the fake host repoints its state.
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module $script:DriverPath -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Test.MacUtmFakeHost.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'host/Yuruna.Host.Contract.psm1') -DisableNameChecking
    $script:Driver = Get-MacUtmFakeDriver
    $script:CanShim = -not $IsWindows
    if ($script:CanShim) {
        $script:FakeRoot = Join-Path ([IO.Path]::GetTempPath()) ("yrn-macprobe-" + [guid]::NewGuid().ToString('N'))
        $script:Fake = New-MacUtmFakeHost -Root $script:FakeRoot
    }

    function Use-FakeHost {
        param([string]$SessionKind = 'Aqua', [string]$Utmctl = 'path')
        Exit-MacUtmFakeHost -FakeHost $script:Fake
        Enter-MacUtmFakeHost -FakeHost $script:Fake -SessionKind $SessionKind -Utmctl $Utmctl
    }
    function Invoke-InDriver {
        param([scriptblock]$Body, [object[]]$Argument = @())
        return (& $script:Driver $Body @Argument)
    }
    function Get-Call { param([string]$Tool) return @(Get-MacUtmFakeCall -FakeHost $script:Fake -Tool $Tool) }
}

AfterAll {
    if ($script:Fake) { Remove-MacUtmFakeHost -FakeHost $script:Fake }
}

Describe 'macOS driver contract coverage' {
    It 'defines, exports and declares every contract verb exactly once' {
        $text = Get-Content -Raw -LiteralPath $script:DriverPath
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
        $exportText = [regex]::Match($text, '(?ms)^Export-ModuleMember -Function.*?(?=^\s*$)').Value
        $declared = [regex]::Match($text, '(?ms)Assert-YurunaHostContractCoverage -HostType ''macos\.utm''.*?^\)').Value
        # The accessor returns its array comma-wrapped; assigning it (rather
        # than wrapping the call in @()) yields the verbs themselves.
        $verbs = Get-YurunaHostContractVerb
        Assert-True ($verbs.Count -ge 40) 'the contract lists its verbs'
        foreach ($verb in $verbs) {
            $defs = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $verb }, $true))
            Assert-Equal -Expected 1 -Actual $defs.Count -Because "$verb must be defined exactly once"
            Assert-Match "(?<![\w-])$([regex]::Escape($verb))(?![\w-])" $exportText "$verb must be exported"
            Assert-Match "'$([regex]::Escape($verb))'" $declared "$verb must be declared to the coverage check"
        }
    }

    It 'imports in a fresh process without a missing-verb warning' {
        $command = "Import-Module '$($script:DriverPath)' -Force -DisableNameChecking 3>&1 | ForEach-Object { 'WARN: ' + `$_ }"
        $output = @(& ([Environment]::ProcessPath) -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | ForEach-Object { ("$_" -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '') })
        $warnings = @($output | Where-Object { $_ -match '^WARN: ' })
        Assert-Equal -Expected 0 -Actual $warnings.Count -Because 'a fresh import must not warn'
    }

    It 'replaces a stale macOS host-condition module instead of failing to import' {
        # A long-lived process can hold a copy loaded before the bundle-path
        # getter and the bounded session probe existed. Removing the one and
        # shadowing the other with an unbounded form stands in for that copy.
        $macPath = Join-Path $PSScriptRoot 'Test.HostCondition.Mac.psm1'
        $lines = @(
            "`$ErrorActionPreference = 'Stop'"
            "Import-Module '$macPath' -Global -DisableNameChecking"
            'Remove-Item -LiteralPath Function:\Get-MacUtmctlBundlePath'
            "Set-Item -Path Function:\global:Get-MacSessionKind -Value { param() 'Aqua' }"
            "Import-Module '$($script:DriverPath)' -Force -DisableNameChecking -WarningAction SilentlyContinue"
            "'BUNDLE=' + (& (Get-Module -Name 'Yuruna.Host') { `$script:UtmctlBundlePath })"
            "'GETTER=' + [bool](Get-Command -Name 'Get-MacUtmctlBundlePath' -CommandType Function -ErrorAction SilentlyContinue)"
            "'BOUNDED=' + (Get-Command -Name 'Get-MacSessionKind').Parameters.ContainsKey('TimeoutSeconds')"
        )
        $output = @(& ([Environment]::ProcessPath) -NoLogo -NoProfile -NonInteractive -Command ($lines -join "`n") 2>&1 | ForEach-Object { ("$_" -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '') })
        Assert-True ($output -contains 'BUNDLE=/Applications/UTM.app/Contents/MacOS/utmctl') "the driver loaded with its bundle path ($($output -join ' | '))"
        Assert-True ($output -contains 'GETTER=True') 'the missing getter is back'
        Assert-True ($output -contains 'BOUNDED=True') 'the session probe is the bounded one again'
    }
}

Describe 'Test-VirtualizationResponsive (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'returns the v1 record with every field typed' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $r = Test-VirtualizationResponsive
        Assert-StringEqual 'Yuruna.VirtualizationProbe' $r.PSObject.TypeNames[0]
        Assert-Equal 1 $r.schemaVersion
        Assert-StringEqual 'host.macos.utm' $r.hostType
        Assert-StringEqual 'Responsive' $r.state
        Assert-StringEqual 'responsive' $r.reason
        Assert-True ($r.started -is [bool] -and $r.started) 'started is a bool and true'
        Assert-True ($r.timedOut -is [bool] -and -not $r.timedOut) 'timedOut is a bool'
        Assert-True ($r.deadlineExhausted -is [bool]) 'deadlineExhausted is a bool'
        Assert-True ($r.corroborated -is [bool] -and -not $r.corroborated) 'corroborated is a bool'
        Assert-True ($r.elapsedMs -is [long]) 'elapsedMs is a long'
        Assert-True ($r.observedTick -is [long]) 'observedTick is a long'
        Assert-True ([DateTime]::Parse($r.observedUtc) -is [DateTime]) 'observedUtc parses'
        foreach ($key in 'utmctlSource', 'sessionKind', 'appState', 'automationGrant', 'exitCode', 'drainTimedOut', 'outputTruncated') {
            Assert-True ($r.evidence.PSObject.Properties.Name -contains $key) "evidence carries $key"
        }
        Assert-StringEqual 'path' $r.evidence.utmctlSource
        Assert-StringEqual 'Aqua' $r.evidence.sessionKind
        Assert-StringEqual 'running' $r.evidence.appState
        Assert-True ($r.diagnostic.Length -le 1024) 'the diagnostic is capped'
        Assert-Match '^uid=501;' $r.automationSubject
        Assert-Null $r.inventory 'no inventory unless asked'
    }

    It 'attaches a typed inventory for zero, one and many VMs' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $zero = Test-VirtualizationResponsive -IncludeInventory
        Assert-True $zero.inventory.Listed 'an empty listing with a header is a listing'
        Assert-True ($zero.inventory.Row -is [object[]] -and $zero.inventory.Row.Count -eq 0) 'zero rows stay an array'
        Assert-True ($zero.inventory.Name -is [string[]] -and $zero.inventory.Name.Count -eq 0) 'zero names stay an array'
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'yuruna-stash-service' -Status 'started'
        $one = Test-VirtualizationResponsive -IncludeInventory
        Assert-True ($one.inventory.Name -is [string[]] -and $one.inventory.Name.Count -eq 1) 'one name stays an array'
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'test vm with spaces' -Status 'started'
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'stopped-vm' -Status 'stopped'
        $many = Test-VirtualizationResponsive -IncludeInventory
        Assert-Equal 3 $many.inventory.Row.Count
        Assert-Equal 2 $many.inventory.Name.Count
        Assert-True ($many.inventory.Name -contains 'test vm with spaces') 'a name with spaces is kept whole'
    }

    It 'resolves utmctl from the UTM bundle when no link is on PATH' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Use-FakeHost -Utmctl 'bundle'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $resolved = Resolve-UtmctlExecutable
        Assert-StringEqual 'bundle' $resolved.Source
        Assert-False $resolved.LinkOnPath 'the link is reported missing'
        Assert-True $resolved.BundlePresent 'the bundle copy is found'
        $r = Test-VirtualizationResponsive
        Assert-StringEqual 'Responsive' $r.state
        Assert-StringEqual 'bundle' $r.evidence.utmctlSource
        Assert-Equal 0 (Get-Call 'sudo').Count -Because 'resolving never repairs the link'
    }

    It 'reports missing-client without launching anything when utmctl is nowhere' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Use-FakeHost -Utmctl 'missing'
        $r = Test-VirtualizationResponsive
        Assert-StringEqual 'Undetermined' $r.state
        Assert-StringEqual 'missing-client' $r.reason
        Assert-False $r.started
        Assert-StringEqual 'missing' $r.evidence.utmctlSource
    }

    It 'refuses a <Kind> session without invoking utmctl' -TestCases @(@{ Kind = 'Remote' }, @{ Kind = 'Unknown' }) {
        param($Kind)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Use-FakeHost -SessionKind $Kind
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $r = Test-VirtualizationResponsive
        Assert-StringEqual 'Undetermined' $r.state
        Assert-StringEqual 'no-session' $r.reason
        Assert-Equal 0 (Get-Call 'utmctl').Count -Because 'no Apple Event from a session that cannot answer a dialog'
    }

    It 'reports app-stopped from a same-user census with neither UTM nor helpers' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        # Another user's UTM is not this user's.
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 700 -Name 'UTM' -Uid '502'
        $r = Test-VirtualizationResponsive
        Assert-StringEqual 'Unresponsive' $r.state
        Assert-StringEqual 'app-stopped' $r.reason
        Assert-StringEqual 'absent' $r.evidence.appState
        Assert-Equal 0 (Get-Call 'utmctl').Count -Because 'an Apple Event to a stopped UTM would launch it'
        $census = Get-Call 'pgrep'
        Assert-True ($census.Count -ge 2) 'both census reads ran'
        foreach ($line in $census) { Assert-Match ' -U 501 ' $line 'every census read is scoped to this user' }
    }

    It 'still probes when the census cannot be read' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'pgrep.mode' -Value 'fail'
        $r = Test-VirtualizationResponsive
        Assert-StringEqual 'unknown' $r.evidence.appState
        Assert-StringEqual 'Responsive' $r.state -Because 'an unknown census is not absence'
        Assert-Equal 1 (Get-Call 'utmctl').Count
    }

    It 'classifies <Mode> as <State>/<Reason>' -TestCases @(
        @{ Mode = 'deny';         State = 'Undetermined'; Reason = 'permission-denied' }
        @{ Mode = 'deny-text';    State = 'Undetermined'; Reason = 'permission-denied' }
        @{ Mode = 'ssh';          State = 'Undetermined'; Reason = 'no-session' }
        @{ Mode = 'oserr';        State = 'Undetermined'; Reason = 'provider-error' }
        @{ Mode = 'curly';        State = 'Undetermined'; Reason = 'provider-error' }
        @{ Mode = 'garbage';      State = 'Undetermined'; Reason = 'invalid-response' }
        @{ Mode = 'empty';        State = 'Undetermined'; Reason = 'invalid-response' }
        @{ Mode = 'big';          State = 'Undetermined'; Reason = 'invalid-response' }
        @{ Mode = 'header';       State = 'Responsive';   Reason = 'responsive' }
        @{ Mode = 'timeout-text'; State = 'Undetermined'; Reason = 'timeout' }
    ) {
        param($Mode, $State, $Reason)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'list.mode' -Value $Mode
        $r = Test-VirtualizationResponsive
        Assert-StringEqual $State $r.state "mode $Mode"
        Assert-StringEqual $Reason $r.reason "mode $Mode"
        if ($Mode -eq 'big') { Assert-True $r.evidence.outputTruncated 'the cut output is reported' }
        if ($Mode -eq 'timeout-text') { Assert-True $r.timedOut '-1712 is a timeout' }
    }

    It 'reports an uncorroborated timeout as Undetermined within its bound' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'list.mode' -Value 'hang'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-VirtualizationResponsive -TimeoutSeconds 2
        Assert-True ($sw.Elapsed.TotalSeconds -lt 6) "bounded ($($sw.Elapsed.TotalSeconds) s)"
        Assert-StringEqual 'Undetermined' $r.state
        Assert-StringEqual 'timeout' $r.reason
        Assert-True $r.timedOut
        Assert-False $r.corroborated
    }

    It 'corroborates a timeout only with a recorded Automation subject' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'list.mode' -Value 'hang'
        $unrecorded = Test-VirtualizationResponsive -TimeoutSeconds 1 -Corroborate -DialogWindowSeconds 0
        Assert-StringEqual 'Undetermined' $unrecorded.state
        Assert-StringEqual 'timeout' $unrecorded.reason
        Assert-StringEqual 'unknown' $unrecorded.evidence.automationGrant
        Assert-Equal 2 (Get-Call 'utmctl').Count -Because 'a second probe was issued after the window'
        $subject = Invoke-InDriver { Get-UtmAutomationSubject }
        $recorded = Test-VirtualizationResponsive -TimeoutSeconds 1 -Corroborate -DialogWindowSeconds 0 -RecordedAutomationSubject @('other', $subject)
        Assert-StringEqual 'Unresponsive' $recorded.state
        Assert-StringEqual 'timeout' $recorded.reason
        Assert-True $recorded.corroborated
        Assert-StringEqual 'recorded' $recorded.evidence.automationGrant
    }

    It 'never counts a subject built without a uid as a recorded grant' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'list.mode' -Value 'hang'
        # The uid read behind the subject fails; the census reads after it answer.
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'id.queue' -Value 'fail'
        $unknownSubject = "uid=unknown;bundle=$($env:__CFBundleIdentifier);term=$($env:TERM_PROGRAM)"
        $r = Test-VirtualizationResponsive -TimeoutSeconds 1 -Corroborate -DialogWindowSeconds 0 -RecordedAutomationSubject @($unknownSubject)
        Assert-StringEqual $unknownSubject $r.automationSubject
        Assert-StringEqual 'running' $r.evidence.appState -Because 'the census itself had a uid'
        Assert-StringEqual 'unknown' $r.evidence.automationGrant
        Assert-False $r.corroborated
        Assert-StringEqual 'Undetermined' $r.state
        Assert-StringEqual 'timeout' $r.reason
    }

    It 'qualifies an Automation subject only with a numeric uid and an exact recorded match' {
        $cases = @(
            @{ Subject = 'uid=501;bundle=;term=';     Recorded = @('uid=501;bundle=;term=');     Expected = $true }
            @{ Subject = 'uid=unknown;bundle=;term='; Recorded = @('uid=unknown;bundle=;term='); Expected = $false }
            @{ Subject = 'uid=501;bundle=;term=';     Recorded = @('UID=501;bundle=;term=');     Expected = $false }
            @{ Subject = 'uid=501;bundle=;term=';     Recorded = @();                            Expected = $false }
            @{ Subject = '';                          Recorded = @('');                          Expected = $false }
        )
        foreach ($case in $cases) {
            $got = Invoke-InDriver { param($s, $r) Test-UtmAutomationSubjectQualified -Subject $s -RecordedSubject $r } @($case.Subject, [string[]]$case.Recorded)
            Assert-Equal $case.Expected $got -Because "'$($case.Subject)' against '$($case.Recorded -join ',')'"
        }
    }

    It 'lets the second probe overrule the first: <Second> -> <State>/<Reason>' -TestCases @(
        @{ Second = 'ok';           State = 'Responsive';   Reason = 'responsive' }
        @{ Second = 'deny';         State = 'Undetermined'; Reason = 'permission-denied' }
        @{ Second = 'garbage';      State = 'Undetermined'; Reason = 'invalid-response' }
        @{ Second = 'timeout-text'; State = 'Unresponsive'; Reason = 'timeout' }
    ) {
        param($Second, $State, $Reason)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'list.queue' -Value "timeout-text`n$Second"
        $subject = Invoke-InDriver { Get-UtmAutomationSubject }
        $r = Test-VirtualizationResponsive -Corroborate -DialogWindowSeconds 0 -RecordedAutomationSubject $subject
        Assert-StringEqual $State $r.state
        Assert-StringEqual $Reason $r.reason
        Assert-Equal ($State -eq 'Unresponsive') $r.corroborated
    }

    It 'reports app-stopped when UTM is gone by the second look' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'list.mode' -Value 'hang'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'pgrep.queue' -Value "normal`nnormal`nnone`nnone"
        $subject = Invoke-InDriver { Get-UtmAutomationSubject }
        $r = Test-VirtualizationResponsive -TimeoutSeconds 1 -Corroborate -DialogWindowSeconds 0 -RecordedAutomationSubject $subject
        Assert-StringEqual 'Unresponsive' $r.state
        Assert-StringEqual 'app-stopped' $r.reason
        Assert-Equal 1 (Get-Call 'utmctl').Count -Because 'no second Apple Event once UTM is gone'
    }

    It 'leaves the timeout uncorroborated when the deadline cannot fit the dialog window' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'list.mode' -Value 'hang'
        $deadline = New-YurunaDeadline -TotalMilliseconds 6000
        $subject = Invoke-InDriver { Get-UtmAutomationSubject }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-VirtualizationResponsive -TimeoutSeconds 1 -Deadline $deadline -Corroborate -DialogWindowSeconds 30 -RecordedAutomationSubject $subject
        Assert-True ($sw.Elapsed.TotalSeconds -lt 8) 'the window is not waited out past the deadline'
        Assert-StringEqual 'Undetermined' $r.state
        Assert-StringEqual 'timeout' $r.reason
        Assert-Equal 1 (Get-Call 'utmctl').Count
    }

    It 'launches nothing with under one second left' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        $r = Test-VirtualizationResponsive -Deadline (New-YurunaDeadline -TotalMilliseconds 500)
        Assert-StringEqual 'Undetermined' $r.state
        Assert-StringEqual 'deadline-exhausted' $r.reason
        Assert-True $r.deadlineExhausted
        Assert-Equal 0 (Get-MacUtmFakeCall -FakeHost $script:Fake).Count -Because 'no tool of any kind was run'
    }
}

Describe 'The Apple Event wording table' {
    BeforeAll {
        # One fixture per alternative of every row, keyed by the alternative's
        # own pattern text: a wording added to the table without a fixture
        # here fails the first case below.
        $script:WordingFixture = @{
            '-1743\b'                            = 'Error from event: The operation could not be completed. (OSStatus error -1743.)'
            'Not authorized to send Apple events' = 'Error: Not authorized to send Apple events to UTM.'
            '-1712\b'                            = 'Error from event: The operation could not be completed. (OSStatus error -1712.)'
            'AppleEvent timed out'               = 'Error: AppleEvent timed out.'
            'does not work from SSH'             = 'Error: utmctl does not work from SSH sessions or before logging in.'
            'OSStatus error'                     = 'The operation failed (OSStatus error -600.)'
            'couldn.t be completed'              = "The operation couldn$([char]0x2019)t be completed."
            'Error from event'                   = 'Error from event: something else'
            'Apple ?Event'                       = 'The Apple Event was rejected'
        }
        $script:WordingTable = Invoke-InDriver { $script:UtmAppleEventReasonPattern }
    }

    It 'has a fixture for every alternative, and each classifies to its own row' {
        foreach ($row in $script:WordingTable.Keys) {
            foreach ($alternative in ($script:WordingTable[$row] -split '\|')) {
                Assert-True ($script:WordingFixture.ContainsKey($alternative)) "no fixture for '$alternative' ($row)"
                $sample = $script:WordingFixture[$alternative]
                Assert-Match $alternative $sample "the fixture for '$alternative' exercises it"
                Assert-StringEqual $row (Invoke-InDriver { param($t) Get-UtmAppleEventReason -Text $t } @($sample)) "'$sample'"
                Assert-StringEqual 'apple-event' (Invoke-InDriver { param($t) Get-UtmStartFailureKind -Text $t } @($sample)) "'$sample'"
            }
        }
    }

    It 'recognizes the wordings the installer gate matches' {
        foreach ($sample in @('(OSStatus error -1743.)', 'Apple Event', 'utmctl does not work from SSH sessions')) {
            Assert-StringEqual 'apple-event' (Invoke-InDriver { param($t) Get-UtmStartFailureKind -Text $t } @($sample)) "'$sample'"
        }
        $installer = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'install/macos.utm.sh')
        foreach ($word in @('-1743', 'Apple Event', 'does not work from SSH')) {
            Assert-True ($installer.Contains($word)) "the installer still matches '$word'"
        }
    }

    It 'keeps a QEMU failure a QEMU failure even beside Apple Event text' {
        $text = 'QEMU error: QEMU exited from an error: boom (OSStatus error -1743.)'
        Assert-StringEqual 'qemu' (Invoke-InDriver { param($t) Get-UtmStartFailureKind -Text $t } @($text))
    }

    It 'classifies unmatched and empty text as none' {
        Assert-StringEqual 'none' (Invoke-InDriver { Get-UtmAppleEventReason -Text 'all good' })
        Assert-StringEqual 'none' (Invoke-InDriver { Get-UtmAppleEventReason -Text '' })
    }
}

Describe 'GUI-session classification' {
    BeforeAll {
        $script:MacCondition = Get-Module -Name 'Test.HostCondition.Mac' | Select-Object -First 1
    }
    It 'reads <Name>/<Answered>/<Ssh> as <Expected>' -TestCases @(
        @{ Name = 'Aqua';       Answered = $true;  Ssh = '';               Expected = 'Aqua' }
        @{ Name = 'Background'; Answered = $true;  Ssh = '';               Expected = 'Remote' }
        @{ Name = '';           Answered = $false; Ssh = '10.0.0.1 22 x 1'; Expected = 'Remote' }
        @{ Name = '';           Answered = $false; Ssh = '';               Expected = 'Unknown' }
        @{ Name = 'Aqua';       Answered = $false; Ssh = '';               Expected = 'Unknown' }
    ) {
        param($Name, $Answered, $Ssh, $Expected)
        $kind = & $script:MacCondition { param($n, $a, $s) ConvertTo-MacSessionKind -ManagerName $n -Answered $a -SshConnection $s } $Name $Answered $Ssh
        Assert-StringEqual $Expected $kind
    }

    It 'asks launchctl through the bounded tool runner' {
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $PSScriptRoot 'Test.HostCondition.Mac.psm1') -Name 'Get-MacSessionKind'
        $commands = @($fn.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        Assert-True ($commands -notcontains 'launchctl') 'no bare launchctl call'
        Assert-True ($commands -contains 'Invoke-MacBoundedTool') 'the call is bounded'
    }

    It 'answers <Expected> from a launchctl that <Case>, within its bound' -TestCases @(
        @{ Case = 'names the GUI manager';   Mode = '';     Manager = 'Aqua';       Expected = 'Aqua' }
        @{ Case = 'names another manager';   Mode = '';     Manager = 'Background'; Expected = 'Remote' }
        @{ Case = 'never answers';           Mode = 'hang'; Manager = 'Aqua';       Expected = 'Unknown' }
    ) {
        param($Case, $Mode, $Manager, $Expected)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        # The macOS path runs here against the stand-in launchctl: only the
        # platform gate is replaced, and an SSH session of the test runner
        # must not decide the unanswered case.
        $saved = @{
            Gate = & $script:MacCondition { ${function:Test-MacHostPlatform} }
            Ssh = $env:SSH_CONNECTION; Tty = $env:SSH_TTY; Manager = $env:YRN_FAKE_MANAGER
        }
        Reset-MacUtmFakeHost -FakeHost $script:Fake
        Enter-MacUtmFakeHost -FakeHost $script:Fake
        try {
            & $script:MacCondition { Set-Item -Path 'function:script:Test-MacHostPlatform' -Value { $true } }
            Remove-Item -Path 'Env:SSH_CONNECTION', 'Env:SSH_TTY' -ErrorAction SilentlyContinue
            $env:YRN_FAKE_MANAGER = $Manager
            if ($Mode) { Set-MacUtmFakeState -FakeHost $script:Fake -Key 'launchctl.mode' -Value $Mode }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $kind = Get-MacSessionKind -TimeoutSeconds 1 -WarningAction SilentlyContinue
            Assert-True ($sw.Elapsed.TotalSeconds -lt 4) "bounded ($($sw.Elapsed.TotalSeconds) s)"
            Assert-StringEqual $Expected $kind $Case
            Assert-StringEqual 'launchctl managername' ((Get-Call 'launchctl') -join '|') $Case
        } finally {
            & $script:MacCondition { param($Gate) Set-Item -Path 'function:script:Test-MacHostPlatform' -Value $Gate } $saved.Gate
            foreach ($pair in @(@('SSH_CONNECTION', $saved.Ssh), @('SSH_TTY', $saved.Tty), @('YRN_FAKE_MANAGER', $saved.Manager))) {
                if ($null -eq $pair[1]) { Remove-Item -Path "Env:$($pair[0])" -ErrorAction SilentlyContinue }
                else { [Environment]::SetEnvironmentVariable($pair[0], $pair[1]) }
            }
            Exit-MacUtmFakeHost -FakeHost $script:Fake
        }
    }
}

Describe 'Start-VirtualizationServiceIfStopped (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'launches UTM when it is positively stopped for this user' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        $r = Start-VirtualizationServiceIfStopped -TimeoutSeconds 10 -Confirm:$false
        Assert-StringEqual 'Yuruna.VirtualizationStartResult' $r.PSObject.TypeNames[0]
        Assert-Equal 1 $r.schemaVersion
        Assert-StringEqual 'started' $r.outcome
        Assert-StringEqual 'not-applicable' $r.layout
        Assert-True ($r.actions -is [object[]] -and $r.actions.Count -eq 1) 'one action, as an array'
        Assert-StringEqual 'app-launch' $r.actions[0].kind
        Assert-StringEqual 'started' $r.actions[0].result
        Assert-StringEqual 'open -a UTM' ($r.actions[0].command -join ' ')
        Assert-Equal 1 (Get-Call 'open').Count
    }

    It 'leaves a running UTM alone' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $r = Start-VirtualizationServiceIfStopped -TimeoutSeconds 10 -Confirm:$false
        Assert-StringEqual 'already-running' $r.outcome
        Assert-Equal 0 (Get-Call 'open').Count
    }

    It 'refuses and launches nothing: <Case>' -TestCases @(
        @{ Case = 'remote session';  Session = 'Remote'; Uid = '501'; Pgrep = '';     Helpers = $false; Reason = 'no-session' }
        @{ Case = 'root';            Session = 'Aqua';   Uid = '0';   Pgrep = '';     Helpers = $false; Reason = 'root' }
        @{ Case = 'unknown census';  Session = 'Aqua';   Uid = '501'; Pgrep = 'fail'; Helpers = $false; Reason = 'census-unknown' }
        @{ Case = 'orphaned helper'; Session = 'Aqua';   Uid = '501'; Pgrep = '';     Helpers = $true;  Reason = 'helpers-without-app' }
    ) {
        param($Case, $Session, $Uid, $Pgrep, $Helpers, $Reason)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Use-FakeHost -SessionKind $Session
        Set-MacUtmFakeUid -FakeHost $script:Fake -Uid $Uid
        if ($Pgrep) { Set-MacUtmFakeState -FakeHost $script:Fake -Key 'pgrep.mode' -Value $Pgrep }
        if ($Helpers) { Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 610 -Name 'QEMUHelper' }
        $r = Start-VirtualizationServiceIfStopped -TimeoutSeconds 10 -Confirm:$false
        Assert-StringEqual 'refused' $r.outcome $Case
        Assert-StringEqual $Reason $r.reason $Case
        Assert-Equal 0 (Get-Call 'open').Count -Because $Case
    }

    It 'previews under -WhatIf with detection only' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        $r = Start-VirtualizationServiceIfStopped -TimeoutSeconds 10 -WhatIf
        Assert-StringEqual 'preview' $r.outcome
        Assert-Equal 0 (Get-Call 'open').Count
        Assert-True ((Get-Call 'pgrep').Count -ge 2) 'detection still ran'
    }

    It 'maps an unobserved launch to unknown and a refused one to failed' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'open.mode' -Value 'noproc'
        $unknown = Start-VirtualizationServiceIfStopped -TimeoutSeconds 2 -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'unknown' $unknown.outcome
        Assert-StringEqual 'not-observed' $unknown.reason
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'open.mode' -Value 'fail'
        $failed = Start-VirtualizationServiceIfStopped -TimeoutSeconds 2 -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'failed' $failed.outcome
    }

    It 'refuses with no time left or no client' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because 'the stand-in tools are POSIX shell scripts'; return }
        $late = Start-VirtualizationServiceIfStopped -Deadline (New-YurunaDeadline -TotalMilliseconds 300) -Confirm:$false
        Assert-StringEqual 'refused' $late.outcome
        Assert-StringEqual 'deadline-exhausted' $late.reason
        Assert-Equal 0 (Get-MacUtmFakeCall -FakeHost $script:Fake).Count
        Use-FakeHost -Utmctl 'missing'
        $absent = Start-VirtualizationServiceIfStopped -TimeoutSeconds 5 -Confirm:$false
        Assert-StringEqual 'refused' $absent.outcome
        Assert-StringEqual 'missing-client' $absent.reason
    }
}
