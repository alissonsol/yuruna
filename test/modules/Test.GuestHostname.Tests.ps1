<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42904e1e-c247-4036-a38b-fb377e975d26
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest hostname cloud-init credential contract pester
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
    Structural Pester guards on guest hostname propagation and first-login
    credential persistence.
.DESCRIPTION
    The value crosses four files per guest (planner -> runner -> the
    Invoke-PerGuestNewVm dispatcher -> the per-guest New-VM.ps1), and the
    dispatcher forwards -Hostname only to scripts that DECLARE it, dropping
    it on the Verbose stream otherwise. A guest script that templates a
    hostname but forgets the parameter therefore fails silently: the VM
    builds, and the hostname is just wrong. These guards make that omission
    a test failure instead.

    Every per-guest New-VM.ps1 that substitutes HOSTNAME_PLACEHOLDER must
    declare -Hostname, resolve it against a VM-name fallback, and feed the
    placeholder from that resolved value. Guests with a fixed hostname baked
    into their template (caching-proxy-service, stash-service) never substitute the
    placeholder and are correctly out of scope.

    The credential guard keeps SetPassword out of password-rotation retries,
    requires the resulting shell to compute a freshly observed token first,
    and rejects login logic that tries both the old and new passwords.

    Source-text only -- no host driver is imported and no VM is touched.
    Throw-based assertions so the file runs under Pester 3.4 and Pester 5+.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.SequenceResolve.psm1') -Force -Global -DisableNameChecking

function Get-SequenceStepRecord {
    param($Steps, [int]$Depth = 0, [int]$TopIndex = -1)
    $items = @($Steps)
    for ($i = 0; $i -lt $items.Count; $i++) {
        $step = $items[$i]
        if ($step -isnot [System.Collections.IDictionary]) { continue }
        $rootIndex = if ($Depth -eq 0) { $i } else { $TopIndex }
        [pscustomobject]@{ Step = $step; Depth = $Depth; TopIndex = $rootIndex }
        if ($step.Contains('steps')) {
            Get-SequenceStepRecord -Steps ($step['steps']) -Depth ($Depth + 1) -TopIndex $rootIndex
        }
    }
}

# Guest scripts in scope: those that actually template a hostname. The Its that
# iterate them are fed by the file-scope case list below; this run-phase copy
# exists only so the fixture-sanity It can assert the glob still matches.
$script:guestScript = @(
    Get-ChildItem -Path (Join-Path $repoRoot 'host') -Filter 'New-VM.ps1' -Recurse -File |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'HOSTNAME_PLACEHOLDER' }
)

# Source text the It bodies assert against. $script: keeps it reachable from the
# It scopes, which run after this block has returned.
$script:provisionSrc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'host/modules/Yuruna.HostProvision.psm1')
$script:engineSrc    = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.SequenceEngine.psm1')

}

# Case lists for the Describes below. Pester enumerates a Describe -- and with it
# every -TestCases expression -- during discovery, which happens before any
# BeforeAll body runs, so these resolve their own repo root here at file scope. A
# list built inside BeforeAll is still $null at enumeration time, and the Describe
# consuming it then emits no tests at all and passes while asserting nothing.
$discoveryRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

$guestCase = @(
    Get-ChildItem -Path (Join-Path $discoveryRepoRoot 'host') -Filter 'New-VM.ps1' -Recurse -File |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'HOSTNAME_PLACEHOLDER' } |
        ForEach-Object { @{ name = (Split-Path -Leaf $_.Directory.FullName); path = $_.FullName } }
)

# Meta-data templates that carry a hostname placeholder.
$metaCase = @(
    Get-ChildItem -Path (Join-Path $discoveryRepoRoot 'host/vmconfig') -Filter '*.meta-data' -File |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'HOSTNAME_PLACEHOLDER' } |
        ForEach-Object { @{ name = $_.Name; path = $_.FullName } }
)

# Every sequence the framework ships. Project sequences live in a separate
# repo that need not be cloned here, so they are scanned only when present.
$seqFile = @(
    Get-ChildItem -Path (Join-Path $discoveryRepoRoot 'test/sequences') -Filter '*.yml' -Recurse -File
    $projDir = Join-Path $discoveryRepoRoot 'project'
    if (Test-Path -LiteralPath $projDir) {
        Get-ChildItem -Path $projDir -Filter '*.yml' -Recurse -File |
            Where-Object { $_.FullName -match '[\\/]test[\\/](gui|ssh)[\\/]' }
    }
)
$seqCase = @($seqFile | ForEach-Object { @{ name = $_.Name; path = $_.FullName } })

# Discover rotation independently of SetPassword. If a commit is accidentally
# removed from one file, that file must stay in the test instead of selecting
# itself out of the guard.
$passwordSequenceCase = @(
    'start.guest.amazon.linux.2023.yml'
    'start.guest.ubuntu.server.24.yml'
    'start.guest.ubuntu.server.26.yml'
) | ForEach-Object {
    @{ name = $_; path = Join-Path $discoveryRepoRoot "test/sequences/$_" }
}
$expectedPasswordSequencePath = @($passwordSequenceCase.path | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object)
$allFrameworkSequenceFile = @(Get-ChildItem -Path (Join-Path $discoveryRepoRoot 'test/sequences') -Filter '*.yml' -File)

# A glob that stops matching would silently retire its whole Describe, so an
# empty list fails the file outright instead of going quiet.
if ($guestCase.Count -lt 3) { throw "Expected several hostname-templating New-VM.ps1 scripts under $(Join-Path $discoveryRepoRoot 'host'), found $($guestCase.Count). The discovery glob is pointed at the wrong folder." }
if ($metaCase.Count  -lt 1) { throw "Expected at least one *.meta-data template with HOSTNAME_PLACEHOLDER under $(Join-Path $discoveryRepoRoot 'host/vmconfig'), found none." }
if ($seqCase.Count   -lt 1) { throw "Expected at least one sequence .yml under $(Join-Path $discoveryRepoRoot 'test/sequences'), found none." }

Describe 'guest-hostname -- variables.hostname reaches cloud-init local-hostname' {
    It 'finds the templating guest scripts at all (fixture sanity)' {
        Assert-True ($guestScript.Count -ge 3) "expected several hostname-templating guest scripts, found $($guestScript.Count)"
    }

    It 'declares -Hostname so the dispatcher forwards it: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$Hostname\s*=\s*''''') `
            "$name templates a hostname but has no [string]`$Hostname = '' parameter; Invoke-PerGuestNewVm would drop the cascade to Verbose"
    }

    It 'falls back to the VM name when -Hostname is empty: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match [regex]::Escape('$GuestHostname = if ($Hostname) { $Hostname } else { $VMName }')) `
            "$name must keep the VM-name default so callers that pin nothing are unaffected"
    }

    It 'feeds HOSTNAME_PLACEHOLDER from the resolved value, not the VM name: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        $fromVmName = [regex]::Matches($src, 'HOSTNAME_PLACEHOLDER''?\s*(?:,|=)\s*\$VMName')
        Assert-True ($fromVmName.Count -eq 0) `
            "$name still substitutes HOSTNAME_PLACEHOLDER from `$VMName, so a pinned hostname is ignored"
        Assert-True ($src -match 'HOSTNAME_PLACEHOLDER''?\s*(?:,|=)\s*\$GuestHostname') `
            "$name must substitute HOSTNAME_PLACEHOLDER from `$GuestHostname"
    }
}

Describe 'guest-hostname -- instance identity stays pinned to the VM name' {
    # cloud-init re-runs per-instance modules when instance-id changes, and two
    # VMs may legitimately share a pinned hostname. Keying instance-id off the
    # hostname would collide them.
    It 'templates instance-id separately from local-hostname: <name>' -TestCases $metaCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^instance-id:\s*INSTANCE_ID_PLACEHOLDER\s*$') `
            "$name must key instance-id off INSTANCE_ID_PLACEHOLDER, not the hostname"
        Assert-True ($src -match '(?m)^local-hostname:\s*HOSTNAME_PLACEHOLDER\s*$') `
            "$name must still template local-hostname"
    }
}

Describe 'guest-hostname -- the dispatcher forwards under the declare-or-drop rule' {
    It 'introspects the target script for a -Hostname parameter' {
        Assert-True ($script:provisionSrc -match [regex]::Escape("ContainsKey('Hostname')")) `
            'Invoke-PerGuestNewVm must probe for -Hostname before forwarding'
    }
    It 'appends -Hostname to the child argument list' {
        Assert-True ($script:provisionSrc -match [regex]::Escape("@('-Hostname', `$Hostname)")) `
            'a probed-and-present -Hostname must actually reach the child script'
    }
}

Describe 'guest-hostname -- ${hostname} resolves in every sequence, pinned or not' {
    # A sequence matching the shell prompt has to name the guest the way the
    # guest names itself. ${vmName} stops being that the moment anything in the
    # chain pins a hostname -- and the sequence that breaks is often NOT the one
    # that pinned it, but a prereq further down the chain that never mentions
    # hostname at all. Seeding ${hostname} as a built-in that falls back to the
    # VM name is what makes the prompt match correct in both cases.
    It 'seeds ${hostname} as a built-in defaulting to the VM name' {
        Assert-True ($script:engineSrc -match [regex]::Escape('"hostname" = $VMName')) `
            'Invoke-Sequence must seed a ${hostname} built-in, or an unpinned sequence matching on ${hostname} sees an unresolved literal'
    }

    It 'never matches the shell prompt on the VM name: <name>' -TestCases $seqCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -notmatch [regex]::Escape('${username}@${vmName}')) `
            "$name matches the prompt on the VM name; a pinned hostname in ANY sequence of its chain makes that assertion time out"
    }
}

Describe 'agetty nudge ordering -- the redraw precedes the wait it unblocks' {

    # agetty prints "login:" once and never reprints it. Console writes that
    # land afterwards (cloud-init's closing banner, subiquity's tail) scroll the
    # prompt away, and the screen then stops changing -- so an OCR wait for
    # "login:" can only spend its entire budget against a frozen frame. The
    # recovery is a keypress, and it only works if it happens BEFORE the wait.
    #
    # Placed after the wait it is unreachable, because a retry block restarts at
    # its first step: every attempt re-enters the wait that cannot pass and no
    # attempt ever reaches the nudge. That shape cost three full waits per guest
    # on several hosts before it was found, and it is invisible in a passing run
    # because the ordering only matters once the prompt has been overwritten.
    It 'puts the redraw keypress before the login wait in <name>' -TestCases $seqCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        # Only sequences that carry BOTH a redraw nudge and a login wait are in
        # scope; the rest have nothing to order.
        $nudge = [regex]::Match($src, '(?m)^\s*-\s*action:\s*pressKey\s*$.*?redraw a fresh login', 'Singleline')
        $wait  = [regex]::Match($src, '(?m)^\s*-\s*action:\s*(?:waitForText|waitForTextWithNudge)\s*$\r?\n\s*pattern:\s*"[^"]*login:"')
        if (-not ($nudge.Success -and $wait.Success)) { return }
        Assert-True ($nudge.Index -lt $wait.Index) `
            ("$name waits for 'login:' before nudging agetty; a prompt already scrolled away can never appear, " +
             'and a retry restarts at the wait so the nudge below it is unreachable')
    }
}

Describe 'agetty periodic redraw -- Ubuntu cold installs keep one wait deadline' {
    It 'nudges inside the bounded login wait in <name>' -TestCases @(
        @{ name = 'Ubuntu Server 24'; path = Join-Path $discoveryRepoRoot 'test/sequences/start.guest.ubuntu.server.24.yml'; budgetSeconds = 1800 }
        @{ name = 'Ubuntu Server 26'; path = Join-Path $discoveryRepoRoot 'test/sequences/start.guest.ubuntu.server.26.yml'; budgetSeconds = 2400 }
    ) {
        param($name, $path, $budgetSeconds)
        $src = Get-Content -Raw -LiteralPath $path
        $wait = [regex]::Match($src, '(?ms)^\s*-\s*action:\s*waitForTextWithNudge\s*\r?\n(?<body>.*?^\s*description:\s*"OCR:\s*\$\{hostLabel\}\s+login:"\s*$)')
        Assert-True $wait.Success "$name must use the bounded periodic-nudge login wait"
        $body = $wait.Groups['body'].Value
        Assert-True ($body -match "(?m)^\s*timeoutSeconds:\s*$budgetSeconds\s*`$") "$name must preserve its per-attempt install budget of ${budgetSeconds}s"
        Assert-True ($body -match '(?m)^\s*nudgeKey:\s*Enter\s*$') "$name must redraw agetty with Enter"
        Assert-True ($body -match '(?m)^\s*nudgeIntervalSeconds:\s*60\s*$') "$name must recover a hidden prompt within about one minute"
        Assert-True ($body -match '(?m)^\s*freshMatch:\s*true\s*$') "$name must not match stale installer-console residue"
        foreach ($failurePattern in 'install_fail.crash', 'Press enter to start a shell', 'An error occurred') {
            Assert-True ($body -match [regex]::Escape($failurePattern)) "$name must retain installer fast-fail pattern '$failurePattern'"
        }
    }
}

Describe 'credential rotation -- persist only after a confirmed shell login' {
    BeforeAll {
        # The file-scope lists above exist for -TestCases, which is read during
        # discovery. This block reads them from inside an It instead, and a
        # discovery-time variable is not in scope there -- it arrives as $null,
        # which makes the guard enumerate nothing and pass while checking no
        # file at all. Re-derive at run time so what is asserted is the tree.
        $sequenceRoot = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'test/sequences'
        $script:runtimeSequenceFile = @(Get-ChildItem -Path $sequenceRoot -Filter '*.yml' -File)
        $script:runtimeExpectedPasswordPath = @(
            'start.guest.amazon.linux.2023.yml'
            'start.guest.ubuntu.server.24.yml'
            'start.guest.ubuntu.server.26.yml'
        ) | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $sequenceRoot $_)) } | Sort-Object

        if ($script:runtimeSequenceFile.Count -lt 3) {
            throw "Expected the start sequences under $sequenceRoot, found $($script:runtimeSequenceFile.Count)."
        }
    }

    It 'confines SetPassword to the three password-rotating start sequences' {
        $allFrameworkSequenceFile = $script:runtimeSequenceFile
        $expectedPasswordSequencePath = $script:runtimeExpectedPasswordPath
        $inlineWrites = @($allFrameworkSequenceFile | Where-Object {
                (Get-Content -Raw -LiteralPath $_.FullName) -match '\$\{ext:authentication\.SetPassword\('
            })
        Assert-Equal -Expected 0 -Actual $inlineWrites.Count `
            -Because 'an inline extension expression would persist a password without the post-login write guard'

        $actual = @(foreach ($file in $allFrameworkSequenceFile) {
                $sequence = Read-SequenceFile -Path $file.FullName -NoCache
                $records = if ($sequence -is [System.Collections.IDictionary] -and $sequence.Contains('steps')) {
                    @(Get-SequenceStepRecord -Steps ($sequence['steps']))
                } else { @() }
                if ($records | Where-Object {
                        $_.Step['action'] -eq 'callExtension' -and $_.Step['method'] -eq 'authentication.SetPassword'
                    }) {
                    [IO.Path]::GetFullPath($file.FullName)
                }
            })
        $actual = @($actual | Sort-Object)
        Assert-Equal -Expected ($expectedPasswordSequencePath -join "`n") -Actual ($actual -join "`n") `
            -Because 'adding or removing a password commit requires an explicit review of its post-login confirmation'
    }

    It 'puts the sole SetPassword call after the computed shell token in <name>' -TestCases $passwordSequenceCase {
        param($name, $path)
        $sequence = Read-SequenceFile -Path $path -NoCache
        $steps = @($sequence['steps'])
        $records = @(Get-SequenceStepRecord -Steps $steps)

        $commits = @($records | Where-Object {
                $_.Step['action'] -eq 'callExtension' -and $_.Step['method'] -eq 'authentication.SetPassword'
            })
        $tokenInputs = @($records | Where-Object {
                $_.Depth -eq 0 -and $_.Step['action'] -eq 'inputTextAndEnter' -and
                $_.Step['text'] -eq ' echo yuruna_$(seq -s '''' 1 9)_ok'
            })
        $tokenWaits = @($records | Where-Object {
                $_.Depth -eq 0 -and $_.Step['action'] -eq 'waitForText' -and
                $_.Step['pattern'] -eq 'yuruna_123456789_ok' -and [bool]$_.Step['freshMatch']
            })
        $rotationRetries = @($records | Where-Object {
                $_.Depth -eq 0 -and $_.Step['action'] -eq 'retry' -and
                @($_.Step['steps'] | Where-Object { $_['action'] -eq 'passwdPrompt' -and $_['text'] -eq '${newPassword}' }).Count -ge 2
            })
        $loginPasswordPrompts = @($records | Where-Object {
                $_.Step['action'] -eq 'passwdPrompt' -and $_.Step['pattern'] -eq 'Password:'
            })

        Assert-Equal -Expected 1 -Actual $commits.Count -Because "$name must have exactly one password commit"
        Assert-Equal -Expected 0 -Actual $commits[0].Depth -Because "$name must not commit from inside the retry block"
        Assert-Equal -Expected 1 -Actual $rotationRetries.Count -Because "$name must retain its new/retype-password rotation"
        Assert-Equal -Expected 1 -Actual $tokenInputs.Count -Because "$name must ask a live shell to compute the confirmation token"
        Assert-Equal -Expected 1 -Actual $tokenWaits.Count -Because "$name must freshly observe the computed confirmation token"
        Assert-True ($rotationRetries[0].TopIndex -lt $tokenInputs[0].TopIndex) "$name computes the token before password rotation finishes"
        Assert-True ($tokenInputs[0].TopIndex -lt $tokenWaits[0].TopIndex) "$name waits for the token before asking the shell to produce it"
        Assert-True ($tokenWaits[0].TopIndex -lt $commits[0].TopIndex) "$name persists the new password before login success is confirmed"
        Assert-True (@($loginPasswordPrompts | Where-Object { $_.Step['text'] -ne '${currentPassword}' }).Count -eq 0) `
            "$name must not try both old and new passwords at the login prompt"
    }

    It 'fails promptly when rotation is rejected in <name>' -TestCases $passwordSequenceCase {
        param($name, $path)
        $sequence = Read-SequenceFile -Path $path -NoCache
        $records = @(Get-SequenceStepRecord -Steps $sequence['steps'])
        $loginWait = @($records | Where-Object {
                $_.Step['action'] -in @('waitForText', 'waitForTextWithNudge') -and
                $_.Step['pattern'] -like '*login:'
            }) | Select-Object -First 1
        $tokenWait = @($records | Where-Object {
                $_.Step['action'] -eq 'waitForText' -and $_.Step['pattern'] -eq 'yuruna_123456789_ok'
            }) | Select-Object -First 1
        Assert-True ($null -ne $loginWait -and $null -ne $tokenWait) "$name needs login and shell-confirmation waits"
        foreach ($failure in 'passwords do not match', 'Authentication token manipulation error') {
            Assert-True (@($loginWait.Step['failurePatterns']) -contains $failure) "$name must recognize rejected rotation on a retry"
            Assert-True (@($tokenWait.Step['failurePatterns']) -contains $failure) "$name must recognize rejected rotation before persisting the password"
        }
        Assert-True (@($tokenWait.Step['failurePatterns']) -contains 'BAD PASSWORD: The password fails the dictionary check') `
            "$name must retain the specific dictionary rejection"
        foreach ($wait in $loginWait, $tokenWait) {
            Assert-True (@($wait.Step['failurePatterns']) -notcontains 'BAD PASSWORD') "$name must not match unrelated OCR fragments"
            Assert-True (@($wait.Step['failurePatterns']) -notcontains 'Login incorrect') "$name must allow recovery from a failed login attempt"
        }
    }

    It 'bounds the initial password wait before retrying login in <name>' -TestCases $passwordSequenceCase {
        param($name, $path)
        $sequence = Read-SequenceFile -Path $path -NoCache
        $prompts = @(Get-SequenceStepRecord -Steps $sequence['steps'] | Where-Object {
                $_.Step['action'] -eq 'passwdPrompt' -and $_.Step['pattern'] -eq 'Password:'
            })
        Assert-Equal -Expected 1 -Actual $prompts.Count -Because "$name needs one initial password prompt"
        $prompt = $prompts[0].Step
        Assert-Equal -Expected 30 -Actual $prompt['timeoutSeconds'] -Because "$name should retry a lost username promptly"
        Assert-True ([bool]$prompt['sinceStepStart']) "$name must not reuse a prior password prompt"
        foreach ($failure in 'BdsDxe:', 'GNU GRUB') {
            Assert-True (@($prompt['failurePatterns']) -contains $failure) "$name must stop typing credentials at a rebooting guest"
        }
    }
}

Describe 'console workload login confirmation' {
    It 'requires a computed shell token before installing on every Linux guest' {
        foreach ($guest in 'amazon.linux.2023', 'ubuntu.server.24', 'ubuntu.server.26') {
            $path = Join-Path $repoRoot "test/sequences/workload.guest.$guest.yml"
            $sequence = Read-SequenceFile -Path $path -NoCache
            $records = @(Get-SequenceStepRecord -Steps $sequence['steps'])
            $inputs = @($records | Where-Object {
                    $_.Step['action'] -eq 'inputTextAndEnter' -and
                    $_.Step['text'] -eq ' echo yuruna_$(seq -s '''' 1 9)_ok'
                })
            $waits = @($records | Where-Object {
                    $_.Step['action'] -eq 'waitForText' -and $_.Step['pattern'] -eq 'yuruna_123456789_ok' -and
                    [bool]$_.Step['freshMatch']
                })
            Assert-Equal -Expected 1 -Actual $inputs.Count -Because "$guest must ask a shell to compute the token"
            Assert-Equal -Expected 1 -Actual $waits.Count -Because "$guest must observe the token"
            Assert-True ($inputs[0].TopIndex -lt $waits[0].TopIndex) "$guest must compute before matching"
        }
    }

    It 'does not put the Amazon install success token in the command echo' {
        $path = Join-Path $repoRoot 'test/sequences/workload.guest.amazon.linux.2023.yml'
        $sequence = Read-SequenceFile -Path $path -NoCache
        $records = @(Get-SequenceStepRecord -Steps $sequence['steps'])
        $install = @($records | Where-Object {
                $_.Step['action'] -eq 'inputTextAndEnter' -and $_.Step['text'] -like '*groupinstall*'
            }) | Select-Object -First 1
        Assert-True ($null -ne $install) 'the Desktop install command must exist'
        Assert-True ($install.Step['text'] -notlike '*DESKTOP_INSTALL_DONE*') 'typing the command cannot prove it succeeded'
        Assert-True ($install.Step['text'] -like '*&& echo*') 'only successful installation may emit its confirmation'
    }
}
