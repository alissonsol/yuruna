<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42c1f70a-8d35-4e63-9a27-5b48c1e07d92
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test vnc display port collision utm pester
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
    Coverage for VNC display allocation on host.macos.utm: reading the
    display a bundle actually carries, rewriting it, bind-testing a port,
    and picking a free display -- plus the structural guards that keep a
    failed VM start from being reported as success.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester
    3.4 and Pester 5+. The bundle cases build a throwaway .utm directory
    holding only a config.plist, so nothing here touches a real VM, and
    the whole file skips on a non-macOS host where plutil/PlistBuddy do
    not exist.
    Run: Invoke-Pester -Path test/modules/Test.VncDisplay.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$VncRepoRoot = Split-Path -Parent (Split-Path -Parent $here)
$VncIsMac = $IsMacOS -and (Test-Path '/usr/libexec/PlistBuddy')
if ($VncIsMac) {
    Import-Module (Join-Path $VncRepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
}

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

# A bundle is just a directory with a config.plist, so a fixture needs no
# disk image and no UTM. $PID keeps the path stable across the discovery
# pass and the execution pass.
$VncTestHome = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-vnc-$PID"
function New-VncFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes only into the suite-owned temp bundle root the suite removes when it ends.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName, [int]$Display)
    $bundle = Join-Path $VncTestHome "yuruna/guest.nosync/$VMName.utm"
    New-Item -ItemType Directory -Force -Path $bundle | Out-Null
    $plist = Join-Path $bundle 'config.plist'
    @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>QEMU</key>
  <dict>
    <key>AdditionalArguments</key>
    <array>
      <string>-vnc</string>
      <string>127.0.0.1:$Display,share=force-shared</string>
      <string>-global</string>
      <string>virtio-gpu-pci.xres=1920</string>
    </array>
  </dict>
  <key>Information</key>
  <dict><key>Name</key><string>$VMName</string></dict>
</dict>
</plist>
"@ | Set-Content -LiteralPath $plist -Encoding utf8
    return $bundle
}

Describe 'VNC display allocation (host.macos.utm)' {

    It 'reads the display the bundle actually carries, not the name hash' {
        if (-not $VncIsMac) { return }
        # The bundle is the authority: the display is written when the VM is
        # built and may be rewritten at start, so a caller that trusted the
        # name hash would aim a screenshot at another VM's framebuffer.
        $prev = $HOME
        try {
            $null = New-VncFixture -VMName 'fixture-vm' -Display 47
            Set-Variable -Name HOME -Value $VncTestHome -Scope Global -Force
            Assert-Equal 47 (Get-VncDisplayFromBundle -VMName 'fixture-vm') -Because 'reads the recorded display'
            Assert-Equal 5947 (Get-VncPortForVm -VMName 'fixture-vm') -Because 'port comes from the bundle'
            $hashPort = 5900 + (Get-VncDisplayForVm -VMName 'fixture-vm')
            Assert-True ($hashPort -ne 5947) 'the fixture pins a display the hash would not choose, so this proves the source'
        } finally { Set-Variable -Name HOME -Value $prev -Scope Global -Force }
    }

    It 'returns -1 for a VM with no bundle so callers can fall back' {
        if (-not $VncIsMac) { return }
        $prev = $HOME
        try {
            Set-Variable -Name HOME -Value $VncTestHome -Scope Global -Force
            Assert-Equal (-1) (Get-VncDisplayFromBundle -VMName 'no-such-vm-here')
            # The port helper still answers, from the hash.
            Assert-True ((Get-VncPortForVm -VMName 'no-such-vm-here') -ge 5910) 'falls back to the name-derived port'
        } finally { Set-Variable -Name HOME -Value $prev -Scope Global -Force }
    }

    It 'rewrites the display and preserves the argument suffix' {
        if (-not $VncIsMac) { return }
        # share=force-shared is what lets the screenshot client attach while
        # the console is open; dropping it would break capture rather than
        # the start, so it must survive the rewrite.
        $prev = $HOME
        try {
            $bundle = New-VncFixture -VMName 'rewrite-vm' -Display 47
            Set-Variable -Name HOME -Value $VncTestHome -Scope Global -Force
            Assert-True (Set-VncDisplayInBundle -VMName 'rewrite-vm' -Display 25 -Confirm:$false) 'rewrite reports success'
            Assert-Equal 25 (Get-VncDisplayFromBundle -VMName 'rewrite-vm') -Because 'the new display is persisted'
            $raw = Get-Content -Raw (Join-Path $bundle 'config.plist')
            Assert-True ($raw -match '127\.0\.0\.1:25,share=force-shared') 'suffix preserved'
        } finally { Set-Variable -Name HOME -Value $prev -Scope Global -Force }
    }

    It 'bind-tests a port rather than assuming it is free' {
        if (-not $VncIsMac) { return }
        # A connect probe cannot tell "nothing listening" from "listening and
        # refusing"; only a bind tells us whether QEMU will be able to bind.
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $taken = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        try {
            Assert-True (-not (Test-VncPortFree -Port $taken)) 'an occupied port reports busy'
        } finally { $listener.Stop() }
        Assert-True (Test-VncPortFree -Port $taken) 'the same port reports free once released'
    }

    It 'skips a taken display and stays inside the 10..89 range' {
        if (-not $VncIsMac) { return }
        $preferred = 40
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 5900 + $preferred)
        $listener.Start()
        try {
            $chosen = Find-FreeVncDisplay -Preferred $preferred
            Assert-True ($chosen -ne $preferred) 'the occupied preference is not returned'
            Assert-True ($chosen -ge 10 -and $chosen -le 89) "chosen display $chosen is inside 10..89"
        } finally { $listener.Stop() }
        Assert-Equal $preferred (Find-FreeVncDisplay -Preferred $preferred) -Because 'a free preference is honoured'
    }

    It 'refuses a display another bundle already claims, even though its port binds free' {
        if (-not $VncIsMac) { return }
        # The whole fleet is stopped between cycles, so every port answers
        # "free" and a bind test alone hands two VMs the same display. Only
        # the first of them can then start.
        $prev = $HOME
        try {
            $null = New-VncFixture -VMName 'claimed-vm' -Display 41
            $null = New-VncFixture -VMName 'seeking-vm' -Display 41
            Set-Variable -Name HOME -Value $VncTestHome -Scope Global -Force
            Assert-True (Test-VncPortFree -Port 5941) 'the fixture claims a display whose port is genuinely free'
            $others = Get-ClaimedVncDisplay -ExcludeVMName 'seeking-vm'
            Assert-True ($others -contains 41) 'the other bundle claim is visible'
            Assert-True ($others -notcontains 99) 'only recorded displays are reported'
            $chosen = Find-FreeVncDisplay -Preferred 41 -ExcludeDisplays $others
            Assert-True ($chosen -ne 41) 'the claimed display is not handed out a second time'
            Assert-True ($chosen -ge 10 -and $chosen -le 89) "chosen display $chosen is inside 10..89"
        } finally { Set-Variable -Name HOME -Value $prev -Scope Global -Force }
    }
}

Describe 'A failed VM start is never reported as success' {

    It 'Start-UtmVM keeps progress off the success stream' {
        # The function returns a status record. Anything written to output
        # becomes part of that return, so a caller checking the shape of the
        # result sees an Object[] instead of the record and skips its own
        # failure check -- which is how a VM that never started was reported
        # as a restored, running guest.
        $text = Get-Content -Raw (Join-Path $VncRepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1')
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Start-UtmVM' }, $true))
        Assert-True ($fn.Count -eq 1) 'Start-UtmVM is defined once'
        $emitters = @($fn[0].FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        Assert-True ($emitters -notcontains 'Write-Output') 'no Write-Output inside a value-returning function'
    }

    It 'resolves the VNC display before starting the VM' {
        # Every guest of a kind is built under the same test-VM name, so a
        # topology that promotes several VMs out of that namespace has them
        # all pinned to one port and only the first can start.
        $text = Get-Content -Raw (Join-Path $VncRepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1')
        $body = [regex]::Match($text, '(?ms)^function Start-UtmVM\b.*?\n\}').Value
        Assert-True ($body -match 'Find-FreeVncDisplay') 'start picks a free display'
        Assert-True ($body -match 'Set-VncDisplayInBundle') 'and records it in the bundle'
        # Anchored on however the start is ISSUED, not on the utmctl verb, which
        # lives in the retrying helper Start-UtmVM delegates to.
        $startMatch = [regex]::Match($body, 'Invoke-UtmVMStartWithRetry|utmctl start')
        Assert-True ($startMatch.Success) 'the start is still there'
        $resolveAt = $body.IndexOf('Find-FreeVncDisplay')
        Assert-True ($resolveAt -ge 0 -and $resolveAt -lt $startMatch.Index) 'the display is resolved BEFORE the start'
    }

    It 'the start path fails when utmctl exits 0 but QEMU died' {
        # utmctl start acknowledges the request, not the guest. QEMU can exit
        # immediately afterwards over a port it cannot bind, and returning
        # success there buys a dead VM a whole sequence of downstream steps.
        $text = Get-Content -Raw (Join-Path $VncRepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1')
        $classify = [regex]::Match($text, '(?ms)^function Get-UtmStartFailureKind\b.*?\n\}').Value
        Assert-True ($classify.Length -gt 0) 'the start-failure classifier is defined'
        Assert-True ($classify -match 'QEMU exited from an error') 'the QEMU death notice is recognised'
        $qemuAt  = $classify.IndexOf("'qemu'")
        $appleAt = $classify.IndexOf("'apple-event'")
        Assert-True ($qemuAt -ge 0 -and $appleAt -ge 0) 'the two failure classes are told apart'
        # Order matters: UTM prints QEMU deaths that also carry an Apple Event
        # phrase, and reading one of those as a transport fault would retry a VM
        # whose process is already dead.
        Assert-True ($qemuAt -lt $appleAt) 'a message naming QEMU is classified as QEMU even when it also carries an Apple Event phrase'

        $starter = [regex]::Match($text, '(?ms)^function Invoke-UtmVMStartWithRetry\b.*?\n\}').Value
        Assert-True ($starter.Length -gt 0) 'the retrying starter is defined'
        Assert-True ($starter -match "kind\s*=\s*'qemu'") 'a QEMU death is returned with its class'
        Assert-True ($starter -match 'success\s*=\s*\$false')  'and as a failure, not a success'
    }

    It 'the start path retries a refused start but never a dead QEMU' {
        # An Apple Event failure means UTM never acted on the request: the VM is
        # untouched and the same call routinely succeeds moments later, so a
        # single attempt turns a momentary refusal into an outage that lasts
        # until an operator types the command by hand -- taking every guest that
        # consumes the service down with it. A QEMU death is the opposite case:
        # the VM launched and its process died, and repeating that only delays
        # the news.
        $text = Get-Content -Raw (Join-Path $VncRepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1')
        $starter = [regex]::Match($text, '(?ms)^function Invoke-UtmVMStartWithRetry\b.*?\n\}').Value
        Assert-True ($starter.Length -gt 0) 'the retrying starter is defined'
        Assert-True ($starter -match 'MaxAttempts') 'it takes an attempt budget'
        Assert-True ($starter -match 'for\s*\(\s*\$attempt') 'and loops over attempts'
        $loopAt       = $starter.IndexOf('for ($attempt')
        $qemuReturnAt = $starter.IndexOf("kind = 'qemu'")
        Assert-True ($loopAt -ge 0 -and $qemuReturnAt -gt $loopAt) 'the QEMU early-out sits inside the retry loop, so it cannot come round again'
        # The verb's own exit code and output are advisory; the VM's observed
        # state is what decides, because utmctl exits 0 for several outcomes
        # that are not a running VM.
        Assert-True ($starter -match 'Get-VMState') 'each attempt is adjudicated by polling the VM state'
    }

    It 'Rename-VM allocates the VNC display while UTM is quit' {
        # UTM reads config.plist when it loads a VM and keeps that copy for the
        # life of the app, so a rewrite performed against a VM it already holds
        # changes the file and not the QEMU command line. The rename is the one
        # window where the file is authoritative again.
        $text = Get-Content -Raw (Join-Path $VncRepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1')
        $body = [regex]::Match($text, '(?ms)^function Rename-VM\b.*?\n\}').Value
        Assert-True ($body -match 'Set-VncDisplayInBundle') 'the rename records a display'
        $quitAt     = $body.IndexOf('to quit')
        $displayAt  = $body.IndexOf('Set-VncDisplayInBundle')
        $relaunchAt = $body.IndexOf('open -a UTM', $displayAt)
        Assert-True ($quitAt -ge 0 -and $quitAt -lt $displayAt) 'UTM is quit before the display is written'
        Assert-True ($relaunchAt -gt $displayAt) 'and relaunched after, so it loads the new value'
        Assert-True ($body -match 'Get-ClaimedVncDisplay') 'the choice avoids displays other bundles claim'
    }

    It 'the AmisAd warm-up refuses to hand the scenarios a half-built topology' {
        # The scenarios that need both edges run last, so a missing edge that
        # only warns here resurfaces much later as a guest script asserting on
        # an absent peer -- naming the wrong scenario and the wrong VM.
        $setResource = Join-Path $VncRepoRoot 'project/test/Set-Resource.ps1'
        if (-not (Test-Path -LiteralPath $setResource)) { return }   # project clone is optional
        $text = Get-Content -Raw $setResource
        Assert-True ($text -match 'Start-VMConfirmed') 'the start is confirmed against observed VM state'
        Assert-True ($text -notmatch 'IP report not seen; dependent scenarios will fall back') 'the warning-only path is gone'
        $deadAt = $text.IndexOf('$deadEdges')
        $liveAt = $text.IndexOf('Warm-up complete. Live:')
        Assert-True ($deadAt -ge 0) 'dead edges are collected'
        Assert-True ($deadAt -lt $liveAt) 'and checked before anything claims the topology is live'
    }

    It 'a host action failing puts its reason in the cycle artifacts, not only the console' {
        # The log proxy tees the Write-* cmdlets and nothing else, so output
        # handed to the console host reaches the terminal and no artifact. A
        # host action that fails that way leaves "FAIL" with an empty reason in
        # the transcript and the event log -- the operator has nothing to read.
        $text = Get-Content -Raw (Join-Path $VncRepoRoot 'test/modules/Test.Orchestrator.psm1')
        $body = [regex]::Match($text, '(?ms)^function Invoke-OrchestratorHostAction\b.*?\n\}').Value
        Assert-True ($body -match '-File \$scriptPath @hostArgs') 'the host script is still dispatched'
        Assert-True ($body -notmatch '@hostArgs\s*\|\s*Out-Host') 'the child output does not go straight to the console host'
        Assert-True ($body -match '@hostArgs 2>&1 \| Write-OrchestratorLine') 'stdout and stderr both go through the tee'
    }

    It 'loadDiskSnapshot fails when Start-VM reports no usable status record' {
        # Guarding on `$result -is [hashtable]` silently accepted a polluted
        # return. The handler must take the record out of whatever came back
        # and treat its absence as failure.
        $text = Get-Content -Raw (Join-Path $VncRepoRoot 'test/modules/Test.SequenceHandler.psm1')
        $i = $text.IndexOf("Register-SequenceAction -Name 'loadDiskSnapshot'")
        Assert-True ($i -ge 0) 'the loadDiskSnapshot handler is registered'
        $body = $text.Substring($i, [Math]::Min(6000, $text.Length - $i))
        Assert-True ($body -notmatch '\$startRes -is \[hashtable\] -and') 'the short-circuiting shape guard is gone'
        Assert-True ($body -match 'Select-Object -Last 1') 'the status record is extracted from the return'
        Assert-True ($body -match 'no status record') 'a missing record fails the step'
    }
}

if (Test-Path -LiteralPath $VncTestHome) {
    Remove-Item -LiteralPath $VncTestHome -Recurse -Force -ErrorAction SilentlyContinue
}
