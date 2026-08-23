<#PSScriptInfo
.VERSION 2026.08.23
.GUID 42b7c9e1-5a4d-4f83-9c26-7d1e08a35b44
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos utm utmctl path pester
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
    Pester coverage for the one thing that makes `utmctl` reachable by name on a
    macOS UTM host, and for the three places that tell an operator how to repair
    it when it is not.
.DESCRIPTION
    UTM keeps its command line inside the app bundle. Nothing about installing
    UTM correctly puts that directory on PATH, and every VM operation in the
    harness shells out to `utmctl` -- so a Mac can finish an install clean, pass
    "UTM.app installed", and still have its very first cycle refused by the
    config gate.

    The failure that costs the operator the most is not the missing link, it is
    being told to run a repair that does not repair anything. These cases pin:

      * the repair command exists in ONE place (Get-MacUtmctlRemediation) and
        every consumer prints that one, including Test-Config's fallback copy
        for a run where the module could not be loaded;
      * Set-MacHostConditionSet actually establishes the link, so
        "rerun Enable-TestAutomation.ps1" -- what both the quick check and
        Test-Config advise -- is true rather than a dead pointer;
      * the bootstrap installer links the SAME path from the SAME bundle
        location, and refuses to report success when it cannot;
      * the installer never routes a brew result through `| grep ... || true`,
        the shape that reported a failed cask install as a successful one.

    Throw-based assertions (no Should), so the file runs standalone. Everything
    here is a decision about text or about the shape of a script, which is why
    it runs off a Mac.
    Run: pwsh -NoProfile -File test/modules/Test.MacUtmctlLink.Tests.ps1
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.Mac.psm1') -Force -DisableNameChecking

    $script:MacModulePath    = Join-Path $here 'Test.HostCondition.Mac.psm1'
    $script:TestConfigSource = Get-Content -LiteralPath (Join-Path $repoRoot 'test/Test-Config.ps1') -Raw
    $script:InstallerSource  = Get-Content -LiteralPath (Join-Path $repoRoot 'install/macos.utm.sh') -Raw

    # One function's text, so a case can assert what that function does without
    # depending on the rest of a 2000-line module.
    function Get-MacFunctionText {
        param([string]$Name)
        $fn = Get-YurunaTestFunctionAst -Path $script:MacModulePath -Name $Name
        if (-not $fn) { return '' }
        return $fn.Extent.Text
    }
}

Describe 'the utmctl repair command' {
    It 'names the in-bundle binary and the /usr/local/bin link' {
        $fix = Get-MacUtmctlRemediation
        Assert-Match ([regex]::Escape('/Applications/UTM.app/Contents/MacOS/utmctl')) $fix `
            'the operator has to be told where UTM hides the binary; a bare "symlink it" is not actionable'
        Assert-Match ([regex]::Escape('/usr/local/bin/utmctl')) $fix `
            '/usr/local/bin is the only bin directory the stock /etc/paths guarantees, so the command has to name it'
        Assert-Match 'ln -sfn' $fix `
            '-n matters: without it, a target that is already a symlink to a directory gets the new link created INSIDE it'
    }

    It 'is the string Test-Config falls back to when the module is unavailable' {
        # Test-Config carries a literal copy for the run in which the host
        # module did not load. A copy that drifts is worse than no copy: the
        # operator pastes it, the gate still fails, and the next thing they
        # stop trusting is the gate.
        Assert-Match "sudo mkdir -p" $script:TestConfigSource 'Test-Config lost its fallback repair command'
        $literal = ([regex]::Match($script:TestConfigSource, "'(sudo mkdir -p [^']+)'")).Groups[1].Value
        Assert-StringEqual (Get-MacUtmctlRemediation) $literal `
            'Test-Config''s fallback copy of the repair command drifted from Get-MacUtmctlRemediation'
    }
}

Describe 'Set-MacUtmctlLink' {
    It 'is a no-op that reports success when the host is not macOS' {
        if ($IsMacOS) { Set-ItResult -Skipped -Because 'the non-macOS early return cannot be observed on a Mac'; return }
        # Not merely "does not throw": the host-settings sweep counts a $false
        # as an unmet condition, and a Windows or Linux run reporting an unmet
        # macOS condition would fail Enable-TestAutomation on every non-Mac.
        Assert-True (Set-MacUtmctlLink) 'the non-macOS path must report success, not an unmet condition'
    }

    It 'writes through sudo rather than assuming the caller is root' {
        $body = Get-MacFunctionText -Name 'Set-MacUtmctlLink'
        Assert-Match 'Invoke-MacPrivilegedSetting' $body `
            'the link needs root; going through the shared helper is what keeps it a warn-with-the-command instead of a password prompt nobody can answer'
        Assert-Match 'Test-MacSudoAvailable' $body `
            'a host that cannot elevate has to be told the command, not left waiting on a prompt'
    }
}

Describe 'the host-settings sweep' {
    It 'establishes the utmctl link, so "rerun Enable-TestAutomation" is a real repair' {
        # Both Test-MacHostMinimum and Test-Config send the operator here. A
        # sweep that configures sleep, lock and TCC but never touches utmctl
        # makes that advice a dead pointer: the operator runs it, nothing about
        # the failure changes, and the next thing they stop trusting is the
        # gate that keeps telling them to run it.
        $body = Get-MacFunctionText -Name 'Set-MacHostConditionSet'
        Assert-Match 'Set-MacUtmctlLink' $body 'Set-MacHostConditionSet no longer establishes the utmctl link'
        Assert-Match "unmet\.Add\('utmctl on PATH'\)" $body `
            'a link the sweep could not create has to raise the unmet count, or Enable-TestAutomation exits 0 on a host that still cannot run a cycle'
    }

    It 'declares the link write among the reasons it asks for sudo' {
        $body = Get-MacFunctionText -Name 'Set-MacHostConditionSet'
        Assert-Match 'utmctl' ([regex]::Match($body, '(?s)Initialize-SudoCache -Reasons @\((.*?)\)\)').Groups[1].Value) `
            'the operator consents to a sudo prompt on the strength of the listed reasons; a write not listed there is one they did not agree to'
    }
}

Describe 'the quick host check' {
    It 'prints the repair command rather than describing it' {
        $body = Get-MacFunctionText -Name 'Test-MacHostMinimum'
        Assert-Match 'Get-MacUtmctlRemediation' $body `
            'the warning has to carry the runnable command; this is the line an operator sees first and most often'
        Assert-Match 'Enable-TestAutomation' $body `
            'the other repair -- the one that also applies the rest of the host settings -- belongs in the same warning'
    }
}

Describe 'the macOS bootstrap installer' {
    It 'links the same path from the same bundle location as the host module' {
        Assert-Match ([regex]::Escape('UTMCTL_BUNDLE="$UTM_APP/Contents/MacOS/utmctl"')) $script:InstallerSource `
            'the installer and the host module must agree on where UTM keeps its CLI'
        # One directory, named once: every tool the installer has to make
        # reachable by name across the whole machine is linked from it, and a
        # second link location would leave two half-configured hosts to tell apart.
        Assert-Match ([regex]::Escape('PATH_LINK_DIR="/usr/local/bin"')) $script:InstallerSource `
            'the link directory has to stay the one the host module also writes to'
        Assert-Match ([regex]::Escape('UTMCTL_LINK="$PATH_LINK_DIR/utmctl"')) $script:InstallerSource `
            'utmctl has to be linked from that same directory, not from a path of its own'
        Assert-Match 'ln -sfn "\$UTMCTL_BUNDLE" "\$UTMCTL_LINK"' $script:InstallerSource `
            'the installer is the one place that can make a fresh Mac work without operator action'
    }

    It 'refuses to finish when UTM is unusable, instead of warning past it' {
        # A warn here and a "Yuruna is ready." twenty lines later is the shape
        # to keep out: an install that cannot start a VM is not ready, and the
        # operator finds out one entry point later, from a gate that blames the
        # harness for what the install left undone.
        Assert-Match '\[\[ -d "\$UTM_APP" \]\] \|\| die' $script:InstallerSource `
            'a missing UTM has to stop the installer'
        Assert-Match '\[\[ -x "\$UTMCTL_BUNDLE" \]\] \|\| die' $script:InstallerSource `
            'an app bundle with no utmctl in it is an incomplete install, not a warning'
        Assert-Match 'command -v utmctl >/dev/null 2>&1 \|\| die' $script:InstallerSource `
            'the installer has to verify the END STATE it claims -- utmctl resolving by name -- not just that it ran ln'
    }

    It 'settles the service-VM question without Apple Events when UTM is not running' {
        # Linking utmctl arms a probe that was unreachable before it: utmctl
        # answers over Apple Events, and a Mac that has not granted Automation
        # to the terminal returns -1743, which the probe's caution arm reads as
        # "a service VM might be running" -- permanently skipping the UTM
        # upgrade on a host with no service VM at all.
        Assert-Match 'pgrep -x UTM' $script:InstallerSource `
            'no VM executes without the UTM process, so its absence has to answer before utmctl is asked'
        $guard = ([regex]::Match($script:InstallerSource, '(?m)^\s*if command -v pgrep .*$')).Value
        Assert-Match 'command -v pgrep' $guard `
            'a host with no pgrep must fall through to the utmctl probe rather than be declared VM-free'
    }

    It 'never reads a brew result through a grep filter' {
        # `brew ... | grep -v <noise> || true` reports GREP's status, so brew's
        # exit code and brew's error text are both discarded and a failed cask
        # install logs exactly like a successful one.
        $offending = @($script:InstallerSource -split "`n" |
            Where-Object { $_ -match '^\s*brew\s+(install|upgrade|reinstall)\b' -and $_ -match '\|\s*grep' })
        Assert-Equal 0 $offending.Count `
            "brew's exit status is being read through a grep filter: $($offending -join ' / ')"
    }
}
