<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42d9fd1b-9965-414d-a198-47696cfff71b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host display scaling dpi ocr pester
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
    Pester coverage for the display-scaling readings behind Test-Config's
    "Display scaling (OCR)" section.
.DESCRIPTION
    A host desktop above 100% scale hands OCR resampled glyphs through every
    window-capture path, and nothing errors when it does: the step burns its
    whole timeoutSeconds and reports 'pattern not found' while the saved frame
    looks readable. The section exists to say so before a cycle pays for it.

    What these cases protect is the honesty of that answer, because every way
    of getting it wrong is silent:

      * DpiValue counts steps from the scale Windows RECOMMENDS for a panel,
        so zero is 100% only on a panel whose recommendation is 100%. Reading
        it as an absolute passes every HiDPI laptop.
      * REG_DWORD reaches PowerShell unsigned, so a stored -2 arrives as
        4294967294. A conversion that throws on either form leaves the value
        unset and reports a clean monitor as scaled.
      * A monitor with no DpiValue is NOT a monitor at 100%. It is one left at
        whatever Windows recommends, which is 125% or 150% on a HiDPI panel,
        and reporting it clean passes exactly the host the check exists for.
      * On macOS, a scaled "More Space" mode is not a defect this pipeline
        has: screencapture reads the backing store upstream of the pass that
        fits the framebuffer to the panel, so those captures still carry two
        pixels per point. Warning on it would name a problem that is not there.
      * The section must WARN and never FAIL. Write-Fail is the only writer
        that moves the exit code, and no per-cycle assertion refuses a cycle
        over scaling.

    Throw-based assertions (no Should), so the file runs standalone. Both
    parsers are pure functions of their inputs, so every case here runs on any
    platform.
    Run: pwsh -NoProfile -File test/modules/Test.DisplayScaleIssue.Tests.ps1
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path $here 'Test.Assert.psm1')                  -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.Windows.psm1')   -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.Mac.psm1')       -Force -DisableNameChecking

    $script:TestConfigSource = Get-Content -LiteralPath (Join-Path $repoRoot 'test/Test-Config.ps1') -Raw
    $script:WinModulePath    = Join-Path $here 'Test.HostCondition.Windows.psm1'

    # Shaped exactly like Get-WindowsDisplayScaleSetting's return, so the rule
    # is fed the structure production hands it rather than a convenient one.
    function Get-WinSettingFixture {
        param($PerMonitor, $LogPixels, $Win8DpiScaling, $TextScaleFactor)
        @{
            PerMonitor      = $PerMonitor
            LogPixels       = $LogPixels
            Win8DpiScaling  = $Win8DpiScaling
            TextScaleFactor = $TextScaleFactor
        }
    }
    function Get-WinMonitorFixture {
        param([string]$Name = 'HWID1', $DpiValue, $RecommendedDpiValue)
        @{ Name = $Name; DpiValue = $DpiValue; RecommendedDpiValue = $RecommendedDpiValue }
    }
    function Get-MacProfileFixture {
        param([int]$PointW, [int]$PointH, [int]$PixelW, [int]$PixelH, [string]$Name = 'Built-in Retina Display')
        @{ SPDisplaysDataType = @(@{ spdisplays_ndrvs = @(@{
            _name                  = $Name
            spdisplays_main        = 'spdisplays_yes'
            spdisplays_online      = 'spdisplays_yes'
            _spdisplays_resolution = "$PointW x $PointH @ 60.00Hz"
            _spdisplays_pixels     = "$PixelW x $PixelH"
        }) }) } | ConvertTo-Json -Depth 8
    }
}

Describe 'Get-WindowsDisplayScaleIssue' {
    It 'reads DpiValue as steps from the recommended scale, not as an absolute' {
        # Zero is 100% only where Windows recommends 100%. On a panel it
        # recommends 150% for, zero IS 150%, and an absolute reading passes it.
        $clean = Get-WindowsDisplayScaleIssue -Setting (Get-WinSettingFixture -PerMonitor @((Get-WinMonitorFixture -DpiValue -2 -RecommendedDpiValue 2)))
        Assert-StringEqual 'Clean' $clean.Status 'a monitor two steps below a recommendation of two steps is at 100%'

        $scaled = Get-WindowsDisplayScaleIssue -Setting (Get-WinSettingFixture -PerMonitor @((Get-WinMonitorFixture -DpiValue 0 -RecommendedDpiValue 2)))
        Assert-StringEqual 'Issue' $scaled.Status 'DpiValue 0 against a recommendation of 2 is 150%, not 100%'
        Assert-Match '150% display scale' $scaled.Issue[0] 'the operator needs the percentage, not the raw offset'
    }

    It 'accepts both the unsigned and the signed form of a REG_DWORD' {
        # The registry surfaces a stored -2 as 4294967294. A [uint32] cast
        # throws on the signed form and a bare [int] cast throws on the
        # unsigned one; either throw leaves the value unset, and the monitor
        # is then reported as scaled when it is at 100%.
        foreach ($raw in @(4294967294, -2)) {
            $r = Get-WindowsDisplayScaleIssue -Setting (Get-WinSettingFixture -PerMonitor @((Get-WinMonitorFixture -DpiValue $raw -RecommendedDpiValue 2)))
            Assert-StringEqual 'Clean' $r.Status "DpiValue $raw is -2 and must read as 100%"
        }
    }

    It 'does not call a host clean when no per-monitor scale is recorded' {
        # The case the check exists for: a fresh HiDPI machine running each
        # display at the recommendation carries no override at all.
        $r = Get-WindowsDisplayScaleIssue -Setting (Get-WinSettingFixture)
        Assert-StringEqual 'Unknown' $r.Status 'an absent override is not evidence of 100%'
        Assert-Equal 0 $r.Issue.Count 'an unmeasured host has no findings to report'
        Assert-Match 'Settings > System > Display' $r.Detail 'the operator has to be told where to read the real value'
    }

    It 'reports the system DPI only while the single-scale mode governs' {
        # LogPixels changes nothing on screen in the per-monitor mode, and
        # naming it would send an operator to a setting that is inert.
        $live = Get-WindowsDisplayScaleIssue -Setting (Get-WinSettingFixture -LogPixels 120 -Win8DpiScaling 1)
        Assert-StringEqual 'Issue' $live.Status 'LogPixels 120 with Win8DpiScaling 1 is a live 125%'
        Assert-Match '125%' $live.Issue[0] 'the finding has to carry the percentage'

        $inert = Get-WindowsDisplayScaleIssue -Setting (Get-WinSettingFixture -LogPixels 120 -Win8DpiScaling 0)
        Assert-StringEqual 'Unknown' $inert.Status 'a leftover LogPixels governs nothing and settles nothing'
    }

    It 'names accessibility text size as its own finding' {
        # It scales text without changing the display scale, and no DPI value
        # includes it, so it needs its own line and its own settings pane.
        $r = Get-WindowsDisplayScaleIssue -Setting (Get-WinSettingFixture -PerMonitor @((Get-WinMonitorFixture -DpiValue -2 -RecommendedDpiValue 2)) -TextScaleFactor 125)
        Assert-StringEqual 'Issue' $r.Status 'text scaling at 125% is a finding even with every display at 100%'
        Assert-Match 'Accessibility' $r.Issue[0] 'the finding has to name the pane that changes it'
    }

    It 'reports one line per monitor that is off 100%' {
        $r = Get-WindowsDisplayScaleIssue -Setting (Get-WinSettingFixture -PerMonitor @(
            (Get-WinMonitorFixture -Name 'GOOD' -DpiValue -2 -RecommendedDpiValue 2),
            (Get-WinMonitorFixture -Name 'BAD'  -DpiValue  0 -RecommendedDpiValue 2)))
        Assert-Equal 1 $r.Issue.Count 'only the monitor that is off 100% is a finding'
        Assert-Match 'BAD' $r.Issue[0] 'the operator has to know which display to change'
    }

    It 'reports an unreadable host as unknown rather than clean' {
        $r = Get-WindowsDisplayScaleIssue -Setting $null
        Assert-StringEqual 'Unknown' $r.Status 'a host that could not be read has not been shown to be at 100%'
    }
}

Describe 'Get-MacDisplayScaleIssue' {
    It 'passes a Retina main display' {
        $r = Get-MacDisplayScaleIssue -Json (Get-MacProfileFixture -PointW 1512 -PointH 982 -PixelW 3024 -PixelH 1964)
        Assert-StringEqual 'Clean' $r.Status 'two pixels per point is what the OCR pipeline is calibrated for'
    }

    It 'does not warn about a scaled mode whose framebuffer is larger than the panel' {
        # screencapture reads the backing store, upstream of the pass that
        # fits the framebuffer to the panel, so a "More Space" mode still
        # delivers two pixels per point. Warning here would name a defect
        # this pipeline does not have.
        $r = Get-MacDisplayScaleIssue -Json (Get-MacProfileFixture -PointW 1710 -PointH 1112 -PixelW 3420 -PixelH 2224)
        Assert-StringEqual 'Clean' $r.Status 'a fractional scaled mode still backs each point with two pixels'
        Assert-Equal 0 $r.Issue.Count 'no finding belongs to a mode the capture path is not hurt by'
    }

    It 'warns when the main display renders one pixel per point' {
        $r = Get-MacDisplayScaleIssue -Json (Get-MacProfileFixture -PointW 2560 -PointH 1440 -PixelW 2560 -PixelH 1440 -Name 'U32J59x')
        Assert-StringEqual 'Issue' $r.Status 'a main display with no HiDPI mode halves the pixels per glyph'
        Assert-Match 'no HiDPI mode' $r.Issue[0] 'the finding has to name what is actually wrong'
        Assert-Match 'U32J59x' $r.Issue[0] 'the operator has to know which display it is'
    }

    It 'reports a session with no window server as unknown, not clean' {
        # A report trimmed to its GPU entries is an answer about the session,
        # not about the displays.
        $json = @{ SPDisplaysDataType = @(@{ _name = 'Apple M2' }) } | ConvertTo-Json -Depth 8
        $r = Get-MacDisplayScaleIssue -Json $json
        Assert-StringEqual 'Unknown' $r.Status 'no display list means nothing was measured'
        Assert-Equal 0 $r.Issue.Count 'an unmeasured host has no findings to report'
    }

    It 'reports unreadable output as unknown' {
        foreach ($bad in @('', '   ', 'not json at all', '{}')) {
            $r = Get-MacDisplayScaleIssue -Json $bad
            Assert-NotEqual 'Clean' $r.Status "input '$bad' proves nothing about this host's scaling"
        }
    }
}

Describe 'the Test-Config display scaling section' {
    It 'keeps the section advisory' {
        # Write-Fail is the only writer that moves the exit code, and no
        # per-cycle assertion refuses a cycle over scaling -- a report that
        # can fail a run over it is one operators stop running.
        $section = [regex]::Match($script:TestConfigSource,
            '(?s)# --- REGION: Section 5c.*?(?=# --- REGION: Section 6)').Value
        Assert-True ($section.Length -gt 0) 'the display scaling section has to exist to be checked'
        Assert-Match 'Write-Warn' $section 'a scaling finding has to reach the operator as a warning'
        Assert-True ($section -notmatch 'Write-Fail') 'the section must never move the exit code'
    }

    It 'renders the probe findings rather than wording of its own' {
        # Two differently worded descriptions of one setting is the failure an
        # operator pays for most: following one and being refused by the other
        # gives no way to tell which is stale.
        $section = [regex]::Match($script:TestConfigSource,
            '(?s)# --- REGION: Section 5c.*?(?=# --- REGION: Section 6)').Value
        Assert-Match 'foreach \(\$scaleIssue in @\(\$scaleReport\.Issue\)\)' $section `
            'the section has to print what the probe found, not restate it'
    }

    It 'states that KVM hosts are not affected rather than passing them' {
        # virsh screenshot reads the libvirt framebuffer and a 'window'
        # request collapses to that same read, so there is no path for host
        # scaling to reach OCR on that family.
        $section = [regex]::Match($script:TestConfigSource,
            '(?s)# --- REGION: Section 5c.*?(?=# --- REGION: Section 6)').Value
        Assert-Match 'host\.ubuntu\.kvm' $section 'the KVM family needs an explicit answer'
        Assert-Match 'Not applicable' $section 'silence would read as "checked and fine"'
    }
}

Describe 'the Windows reader and the applier' {
    It 'decides 100% from the same recommended offset the applier writes' {
        # Two independent notions of what 100% means is how a report passes a
        # host the applier would still change.
        foreach ($name in @('Set-YurunaDisplayScale100', 'Get-WindowsDisplayScaleIssue')) {
            $fn = Get-YurunaTestFunctionAst -Path $script:WinModulePath -Name $name
            Assert-NotNull $fn "$name has to exist for the two to be comparable"
            Assert-Match 'RecommendedDpiValue' $fn.Extent.Text `
                "$name has to decide 100% from the monitor's recommended offset"
        }
    }
}
