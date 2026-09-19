<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42a6b0a3-6ac8-4209-8138-98b813018d22
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic journal libvirt dnsmasq pester
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
# Pester supplies Describe/It/Should here. Without it every one of those calls
# raises CommandNotFoundException, the engine keeps going, and the file reaches
# its end and exits 0 -- so a harness that shells this out records a PASS for a
# suite that executed no assertion at all.
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    The host diagnostic's journal windows carry the host's news, not the
    harness's own, and a libvirt host is asked about the DHCP service it runs.
.DESCRIPTION
    WHY THIS EXISTS. Two properties of the captured artifact decide whether a
    guest that never got a lease can be diagnosed after the fact, and both fail
    quietly:

      * The journal windows are finite, and this harness writes to the journal
        on a timer while a cycle runs -- an apparmor profile reload per console
        frame, a libvirt agent-rung error per address lookup on an image with
        no guest agent, a compile record per child pwsh. Unfiltered, a
        100-line tail of a busy host is entirely its own bookkeeping and every
        line a reader came for has already aged out. The same lines counted as
        errors report a permanent problem no operator can act on.
      * Where libvirt runs the guest network, the host IS the DHCP server its
        guests talk to, and none of the host's own interface, route and socket
        dumps say anything about it. Without the lease table and the dnsmasq
        window, a guest that came up address-less is a failure with no
        server-side record at all: it is destroyed at cleanup minutes later.

    The classifier and the note builder are lifted out of the script and driven
    directly; the sections around them are asserted over the source, because
    running the whole capture needs the host it was captured on.
    Run: Invoke-Pester -Path test/modules/Test.DiagnosticJournalNoise.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $PSScriptRoot 'Test.CatalogSource.psm1') -DisableNameChecking
    $script:DiagPath = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'
    $script:DiagText = Get-Content -Raw -LiteralPath $script:DiagPath

    function Get-PsFunctionText {
        param([string]$Source, [string]$Name)
        $m = [regex]::Match($Source, "(?ms)^function $([regex]::Escape($Name)) \{.*?^\}")
        if (-not $m.Success) { throw "function $Name not found" }
        return $m.Value
    }

    # The two helpers are pure and free of the script's parameters, so they can
    # be defined here and driven directly rather than by running a capture that
    # only reproduces on the host it was taken from.
    . ([scriptblock]::Create((Get-PsFunctionText -Source $script:DiagText -Name 'Get-JournalSelfNoiseClass')))
    . ([scriptblock]::Create((Get-PsFunctionText -Source $script:DiagText -Name 'Format-JournalSelfNoiseNote')))

    $script:NoiseLine = @{
        apparmor = 'Aug 20 16:18:26 host kernel: audit: type=1400 apparmor="STATUS" operation="profile_replace" name="libvirt-4477ac44"'
        agent    = 'Aug 20 16:19:08 host libvirtd[2818]: Guest agent is not responding: QEMU guest agent is not connected'
        compile  = 'Aug 20 16:18:27 host powershell[241621]: [ScriptBlock_Compile_Detail] Creating Scriptblock text (1 of 6): x'
        ipc      = 'Aug 20 17:30:01 host powershell[287287]: [NamedPipeIPC_ServerListenerError:NamedPipe.Exception.Error] Operation canceled.'
    }
}

Describe 'diagnostic journal: the harness does not report itself as news' {

    It 'classifies each shape this harness writes on a timer' {
        foreach ($key in $script:NoiseLine.Keys) {
            (Get-JournalSelfNoiseClass -Line $script:NoiseLine[$key]) |
                Should -Not -BeNullOrEmpty -Because "the $key line is written by this harness simply by running"
        }
    }

    It 'keeps an apparmor denial, which is a fault and not bookkeeping' {
        $denied = 'Aug 20 16:18:26 host kernel: audit: apparmor="DENIED" operation="open" name="/etc/shadow"'
        (Get-JournalSelfNoiseClass -Line $denied) | Should -BeNullOrEmpty -Because 'a profile load is bookkeeping; a denial is the thing a reader is looking for'
    }

    It 'keeps an ordinary host error' {
        $real = 'Aug 20 16:18:26 host kernel: EXT4-fs error (device sda1): ext4_find_entry:1463: inode #2: comm ls'
        (Get-JournalSelfNoiseClass -Line $real) | Should -BeNullOrEmpty
    }

    It 'tallies what it suppressed instead of dropping it silently' {
        $tally = [ordered]@{}
        $tally['apparmor profile reloads'] = 49
        $tally['guest-agent probes'] = 26
        $note = Format-JournalSelfNoiseNote -Tally $tally
        $note | Should -Match '75 line' -Because 'the reader has to know how much was removed to judge what is left'
        $note | Should -Match '49 apparmor profile reloads'
        $note | Should -Match '26 guest-agent probes'
    }

    It 'says nothing when nothing was suppressed' {
        (Format-JournalSelfNoiseNote -Tally ([ordered]@{})) | Should -BeNullOrEmpty
    }

    It 'reads a wider window than it prints, because the noise arrives on a timer' {
        # Filtering a 100-line tail cannot recover what already scrolled out of
        # it: on a host mid-cycle those 100 lines ARE the harness's own polling.
        $script:DiagText | Should -Match "'-xe','-n','400','--no-pager'" -Because 'the window has to be wider than the one printed'
        $script:DiagText | Should -Match '\$kept \| Select-Object -Last 100' -Because 'what is printed stays the size it was'
    }

    It 'counts only entries the harness did not write when deciding there is a problem' {
        $script:DiagText | Should -Match '\$realCount = @\(\$entries \| Where-Object \{ -not \(Get-JournalSelfNoiseClass' `
            -Because 'a host whose error journal is only its own guest-address probes has no problem to report'
        $script:DiagText | Should -Match 'if \(\$realCount -ge 10\)' -Because 'the threshold must be applied to the filtered count'
    }

    It 'does not count journalctl boot separators as errors' {
        # "-- Boot <id> --" is punctuation between boots, not an entry. Counting
        # it adds one phantom error per boot in the window.
        $script:DiagText | Should -Match '\$entries\s+= @\(\$jc \| Where-Object \{ -not \(Test-JournalSeparatorLine' `
            -Because 'separators must be removed before anything is counted'
    }

    It 'reconciles the suppressed count whether or not the problem fires' {
        # The line explains a number the operator can see. Tying it to the quiet
        # case withheld it exactly when the count was being questioned.
        $script:DiagText | Should -Match '\$suppressed = \$entryCount - \$realCount' `
            -Because 'the note reports what was filtered, not what survived'
        $script:DiagText | Should -Match "if \(\`$suppressed -gt 0\) \{" `
            -Because 'suppression is reported on its own terms, not as an else-branch of the threshold'
    }

    It 'still prints every line it was given' {
        # Suppression is for the count and for the window that would otherwise
        # overflow, never for hiding what the journal said in the error section.
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DiagText, [ref]$null, [ref]$null)
        $probe = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Sub' -and $node.Extent.Text -match 'journalctl -p err -n 20' }, $true)
        $probe | Should -Not -BeNullOrEmpty
        $eventsBlock = $probe.Parent.Parent.Extent.Text
        $eventsBlock | Should -Match '\$jc \| ForEach-Object \{ Write-Output \$_ \}' -Because 'the operator must still be able to read what was there'
    }
}

Describe 'diagnostic: a libvirt host is asked about the DHCP service it runs' {

    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DiagText, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Sub' }, $true))
        $begin = @($calls | Where-Object { (($_.Extent.Text + "`n" + ((Get-CatalogSourceMessage -Source $_.Extent.Text) -join "`n"))) -match 'libvirt guest networks' })[0]
        $end = @($calls | Where-Object { $_.Extent.StartOffset -gt $begin.Extent.StartOffset -and (($_.Extent.Text + "`n" + ((Get-CatalogSourceMessage -Source $_.Extent.Text) -join "`n"))) -match 'journalctl -xe' })[0]
        $script:LibvirtBlock = $script:DiagText.Substring($begin.Extent.StartOffset, $end.Extent.StartOffset - $begin.Extent.StartOffset)
    }

    It 'is present at all' {
        $script:LibvirtBlock | Should -Not -BeNullOrEmpty
    }

    It 'asks for the leases, the bridges and the domains a reader has to correlate' {
        $script:LibvirtBlock | Should -Match "'net-dhcp-leases'" -Because 'the lease table is the server-side answer to "did this guest ever get an address"'
        $script:LibvirtBlock | Should -Match "'domiflist'" -Because 'the MAC and bridge are unresolvable once the domain is undefined'
        $script:LibvirtBlock | Should -Match "'net-dumpxml'" -Because 'the range a lease can come from and the bridge it crosses are in the definition'
    }

    It 'reads the server journal by the identifiers dnsmasq logs under' {
        $script:LibvirtBlock | Should -Match "'-t', 'dnsmasq-dhcp', '-t', 'dnsmasq'" `
            -Because 'the transactions are logged under the dhcp identifier, and the plain one carries the startup lines'
    }

    It 'never changes anything it is asked to describe' {
        # A diagnostic that can define, start or destroy a network is a
        # diagnostic that can cause the outage it was run to explain.
        foreach ($verb in "'net-define'", "'net-start'", "'net-destroy'", "'net-update'", "'net-undefine'", "'destroy'", "'undefine'") {
            $script:LibvirtBlock | Should -Not -Match ([regex]::Escape($verb)) -Because "a read-only section must not carry $verb"
        }
    }

    It 'does not report a libvirt host as having no libvirt when it cannot connect' {
        $script:LibvirtBlock | Should -Match 'Invoke-PrivProbe -Tool ''virsh''' `
            -Because 'a runner account outside the libvirt group must be retried, not reported as a host without libvirt'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
