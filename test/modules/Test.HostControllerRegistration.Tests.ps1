<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42133455-646c-4f1b-a9ea-06827d9e94e1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update registration systemd pester
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
    The KVM registration of the host controller: the unit Enable renders and
    installs, the shim and snapshot it deploys, and what Disable removes; on
    macOS, what Disable removes: the controller's session, its files, a
    temporary sudo rule and the sudoers entry.
.DESCRIPTION
    The unit text and the controller files are tested in process against a
    scratch home and a scratch checkout. Each script's host-controller step is
    sliced out between its region markers and run in a child pwsh whose HOME
    is a scratch folder, with stand-ins for sudo, systemctl and getent on a
    private PATH; the unit path is pointed at a scratch file, and the sudo
    stand-in refuses to write anywhere else. The message renderer answers
    with its key and arguments, so no assertion depends on catalog wording.
    Nothing on this machine is registered, started or stopped, and the
    private root under the suite's scratch home is checked to be untouched.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # The private state root and the runner gate resolve under $HOME; a scratch
    # home keeps this suite and every process it starts off the operator's own.
    $script:TestHome = Enter-YurunaTestHome
    Get-Module Test.HostUpdate, Test.HostOperationJournal | Remove-Module -Force -ErrorAction SilentlyContinue
    # One instance of each primitive, shared by this suite and the modules
    # under test: a lock the suite holds must be the one the module probes.
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostOperationJournal.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostUpdate.psm1') -Force -Global -DisableNameChecking
    $script:BypassRoot = Join-Path $HOME '.yuruna/host-repair'
    # The root a call that bypassed its seam would reach under the scratch
    # home. The listing is compared by name, and the host controller's files
    # and the request journal also by time: those are the ones this suite
    # would touch if a seam failed.
    function Get-BypassRootState {
        param()
        if (-not (Test-Path -LiteralPath $script:BypassRoot)) { return '<absent>' }
        @(Get-ChildItem -LiteralPath $script:BypassRoot -Force | ForEach-Object {
                if ($_.Name -match '^(host-controller|host-repair\.)') { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)" } else { $_.Name }
            }) -join ';'
    }
    $script:BypassRootBefore = Get-BypassRootState
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'hu-registration'
    $script:Template = Join-Path $script:RepoRoot 'host/ubuntu.kvm/host-controller/yuruna-host-controller.service'
    $script:KvmHostDir = Join-Path $script:RepoRoot 'host/ubuntu.kvm'
    $script:MacHostDir = Join-Path $script:RepoRoot 'host/macos.utm'
    $script:WindowsHostDir = Join-Path $script:RepoRoot 'host/windows.hyper-v'
    $script:UnitName = 'yuruna-host-controller.service'
    $script:UnitLiteral = "'/etc/systemd/system/yuruna-host-controller.service'"
    $script:HeldLocks = [System.Collections.Generic.List[object]]::new()

    # Admission reads the runner gate by name; an open gate lets a scratch
    # host update be queued and claimed.
    ${function:global:Get-YurunaRunnerGateState} = {
        param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot)
        $null = $RuntimeDir, $TokenId, $PrivateRoot
        [pscustomobject]@{ State = 'open'; RequestId = $null; Generation = ''; Reason = 'test' }
    }

    function ConvertFrom-UnitText {
        param([Parameter(Mandatory)][string]$Text)
        $sections = [ordered]@{}
        $current = $null
        foreach ($line in ($Text -split "`n")) {
            if ($line -match '^\s*(#|$)') { continue }
            if ($line -match '^\[(?<name>[^\]]+)\]$') { $current = $Matches.name; $sections[$current] = [ordered]@{}; continue }
            $at = $line.IndexOf('=')
            $sections[$current][$line.Substring(0, $at)] = $line.Substring($at + 1)
        }
        return $sections
    }

    function New-ScratchHome {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch home and points the module at it.')]
        param()
        $dir = Join-Path $script:ScratchBase ('h-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
        $null = New-Item -ItemType Directory -Path (Join-Path $dir 'runtime') -Force
        & (Get-Module Test.HostOperationJournal) { param($h) $script:HostOperationHomePath = $h } $dir
        return $dir
    }

    function New-ScratchCheckout {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a scratch checkout.')]
        param()
        $tree = Join-Path $script:ScratchBase ('c-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        foreach ($path in @('automation', 'test/modules', 'test/lab')) { $null = New-Item -ItemType Directory -Path (Join-Path $tree $path) -Force }
        Set-Content -LiteralPath (Join-Path $tree 'automation/A.psm1') -Value 'function Get-A { 1 }'
        Set-Content -LiteralPath (Join-Path $tree 'test/modules/B.psm1') -Value 'function Get-B { 2 }'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'test/lab/yuruna-host-controller-shim.sh') -Destination (Join-Path $tree 'test/lab/yuruna-host-controller-shim.sh')
        [System.IO.File]::WriteAllText((Join-Path $tree 'test/host-update.protocol-version'), '1')
        return $tree
    }

    function Enter-ControllerLock {
        # Stands in for a running controller: the probe only asks whether
        # some process holds the lock.
        param()
        $lock = Enter-YurunaSingleFlightLock -Path (Get-HostUpdateControllerLockPath) -WaitMilliseconds 2000
        if (-not $lock.Held) { throw "fixture sanity: controller lock not taken ($($lock.Reason))" }
        $script:HeldLocks.Add($lock)
        return $lock
    }

    function Exit-ControllerLock {
        param([Parameter(Mandatory)]$Lock)
        Exit-YurunaSingleFlightLock -Lock $Lock
        $null = $script:HeldLocks.Remove($Lock)
    }

    function New-StubBin {
        <#
        .SYNOPSIS
            Stand-ins for sudo, systemctl and getent that record their
            arguments under <base>/rec and answer from files there.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes stand-in programs into a scratch folder.')]
        param([string[]]$Group = @('libvirt', 'kvm'), [string]$Enabled = 'disabled', [string]$Active = 'inactive', [string]$FailOn = '')
        $base = Join-Path $script:ScratchBase ('b-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $bin = Join-Path $base 'bin'
        $rec = Join-Path $base 'rec'
        foreach ($dir in @($bin, $rec)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [System.IO.File]::WriteAllText((Join-Path $rec 'groups'), (($Group | ForEach-Object { "$_`n" }) -join ''))
        [System.IO.File]::WriteAllText((Join-Path $rec 'is-enabled'), $Enabled)
        [System.IO.File]::WriteAllText((Join-Path $rec 'is-active'), $Active)
        [System.IO.File]::WriteAllText((Join-Path $rec 'fail'), $FailOn)
        $stub = @{
            sudo      = @'
#!/bin/sh
REC='@REC@'
printf '%s\n' "$*" >> "$REC/sudo.argv"
fail=$(cat "$REC/fail")
if [ -n "$fail" ] && [ "$*" = "$fail" ]; then echo "stub: refused" >&2; exit 1; fi
[ "$1" = "-n" ] && shift
case $1 in
    tee)
        case $2 in '@SCRATCH@'/*) ;; *) echo "stub: refuses $2" >&2; exit 97 ;; esac
        cat > "$2"
        cat "$2"
        ;;
    rm)
        # The temporary rule of a host update is recorded, never touched.
        case $3 in '@SCRATCH@'/*) rm -f "$3" ;; /etc/sudoers.d/yuruna-host-update) ;; *) echo "stub: refuses $3" >&2; exit 97 ;; esac
        ;;
esac
exit 0
'@
            systemctl = @'
#!/bin/sh
REC='@REC@'
printf '%s\n' "$*" >> "$REC/systemctl.argv"
case $1 in
    is-enabled) v=$(cat "$REC/is-enabled"); echo "$v"; [ "$v" = enabled ] ;;
    is-active) v=$(cat "$REC/is-active"); echo "$v"; [ "$v" = active ] ;;
    *) exit 0 ;;
esac
'@
            getent    = @'
#!/bin/sh
REC='@REC@'
if [ "$1" = group ] && grep -qx "$2" "$REC/groups"; then echo "$2:x:990:runner"; exit 0; fi
exit 2
'@
        }
        foreach ($name in $stub.Keys) {
            $path = Join-Path $bin $name
            [System.IO.File]::WriteAllText($path, $stub[$name].Replace('@REC@', $rec).Replace('@SCRATCH@', $script:ScratchBase))
            [System.IO.File]::SetUnixFileMode($path, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        return [pscustomobject]@{ Base = $base; Bin = $bin; Rec = $rec; UnitPath = (Join-Path $base 'yuruna-host-controller.service') }
    }

    function Get-StubCall {
        param([Parameter(Mandatory)]$Stub, [string]$Name = 'sudo')
        $path = Join-Path $Stub.Rec "$Name.argv"
        if (-not (Test-Path -LiteralPath $path)) { return }
        Get-Content -LiteralPath $path
    }

    function Clear-StubCall {
        param([Parameter(Mandatory)]$Stub)
        foreach ($name in @('sudo', 'systemctl')) { Remove-Item -LiteralPath (Join-Path $Stub.Rec "$name.argv") -ErrorAction SilentlyContinue }
    }

    function Get-RegionSlice {
        param([string]$Script, [string]$Region, [string]$NextRegion, [string]$HostDir = $script:KvmHostDir)
        $path = Join-Path $HostDir $Script
        $source = [IO.File]::ReadAllText($path)
        $start = $source.IndexOf("# --- REGION: $Region`n", [StringComparison]::Ordinal)
        $end = if ($start -ge 0) { $source.IndexOf("# --- REGION: $NextRegion", $start, [StringComparison]::Ordinal) } else { -1 }
        if ($start -lt 0 -or $end -le $start) { throw "$Script no longer frames its '$Region' step between two region markers" }
        return $source.Substring($start, $end - $start)
    }

    # The renderer answers with its key and arguments. Defined after the
    # region's own imports, which would otherwise replace it.
    $script:StandIn = @'
function Format-YurunaOperatorMessage {
    param([string]$Key, [hashtable]$Arguments = @{})
    $pairs = @($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" })
    return ((@('MSG', $Key) + $pairs) -join '|')
}
function Start-Sleep { param([int]$Milliseconds) $null = $Milliseconds }
'@

    function Add-StandIn {
        # Puts the stand-ins, and -Extra ones of a case, right after the
        # slice's last import.
        param([Parameter(Mandatory)][string]$Slice, [string]$Extra = '')
        $lines = [System.Collections.Generic.List[string]]::new([string[]]($Slice -split "`n"))
        $last = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^Import-Module ') { $last = $i } }
        if ($last -lt 0) { throw 'fixture sanity: the slice imports nothing' }
        $lines.Insert($last + 1, ($script:StandIn + "`n" + $Extra))
        return ($lines -join "`n")
    }

    function Invoke-Child {
        param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)]$Stub, [Parameter(Mandatory)][string[]]$Text)
        $fixture = Join-Path $Stub.Base ([guid]::NewGuid().ToString('N') + '.ps1')
        [IO.File]::WriteAllText($fixture, ($Text -join "`n") + "`n")
        $lines = @(& /usr/bin/env "HOME=$HomePath" "PATH=$($Stub.Bin):$env:PATH" 'NO_COLOR=1' (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $fixture 2>&1 | ForEach-Object {
                [regex]::Replace([regex]::Replace("$_", '\x1b\[[0-9;?]*[ -/]*[@-~]', ''), '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
            })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines; Text = ($lines -join "`n") }
    }

    function Invoke-EnableStep {
        param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)]$Stub, [bool]$CanSudo = $true, [bool]$NoOperatorPrompt = $false)
        $enable = Join-Path $script:KvmHostDir 'Enable-TestAutomation.ps1'
        $slice = Get-RegionSlice -Script 'Enable-TestAutomation.ps1' -Region 'Host controller' -NextRegion 'Outcome'
        if (([regex]::Matches($slice, [regex]::Escape($script:UnitLiteral))).Count -ne 1) { throw 'fixture sanity: the unit path is not named once in the region' }
        $slice = $slice.Replace($script:UnitLiteral, "'$($Stub.UnitPath)'")
        Invoke-Child -HomePath $HomePath -Stub $Stub -Text @(
            "`$ErrorActionPreference = 'Stop'"
            "`$env:USER = 'runner'"
            "`$RepoRoot = '$($script:RepoRoot)'"
            "`$canSudo = `$$CanSudo"
            "`$NoOperatorPrompt = `$$NoOperatorPrompt"
            '$Script:Unmet = [System.Collections.Generic.List[string]]::new()'
            (Get-YurunaTestFunctionAst -Path $enable -Name 'Invoke-Step').Extent.Text
            (Get-YurunaTestFunctionAst -Path $enable -Name 'Invoke-HostSudo').Extent.Text
            (Add-StandIn -Slice $slice)
            '"UNMET|$($Script:Unmet -join ";")"'
        )
    }

    function Invoke-DisableStep {
        # -OnStop runs in the child right after the stand-in systemctl stop.
        param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)]$Stub, [string]$OnStop = '')
        $guard = Get-RegionSlice -Script 'Disable-TestAutomation.ps1' -Region 'Host update in progress' -NextRegion 'Read captured host settings'
        $removal = Get-RegionSlice -Script 'Disable-TestAutomation.ps1' -Region 'Host controller' -NextRegion 'GNOME idle / lock / dim'
        if (([regex]::Matches($removal, [regex]::Escape($script:UnitLiteral))).Count -ne 1) { throw 'fixture sanity: the unit path is not named once in the region' }
        $removal = $removal.Replace($script:UnitLiteral, "'$($Stub.UnitPath)'")
        $sudo = @'
function Invoke-YurunaSudo {
    param([string[]]$Argument, [switch]$TolerateBlocked)
    $null = $TolerateBlocked
    & sudo @Argument 2>&1 | Out-Null
    $code = $LASTEXITCODE
    if ($Argument[0] -eq 'systemctl' -and $Argument[1] -eq 'stop') { @ONSTOP@ }
    return @{ ExitCode = $code; Output = 'stub output' }
}
'@
        $sudo = $sudo.Replace('@ONSTOP@', $OnStop)
        Invoke-Child -HomePath $HomePath -Stub $Stub -Text @(
            '[CmdletBinding(SupportsShouldProcess)] param()'
            "`$ErrorActionPreference = 'Stop'"
            "`$RepoRoot = '$($script:RepoRoot)'"
            '$restored = [System.Collections.Generic.List[string]]::new()'
            '$skipped = [System.Collections.Generic.List[string]]::new()'
            (Add-StandIn -Slice $guard)
            $sudo
            $removal
            'foreach ($line in $restored) { "RESTORED|$line" }'
            'foreach ($line in $skipped) { "SKIPPED|$line" }'
        )
    }

    function New-MacStubBin {
        <#
        .SYNOPSIS
            Stand-ins for sudo, tmux and screen that record their arguments
            under <base>/rec and answer from files there. sudo never runs a
            command; tmux answers has-session from tmux-session (yes or no)
            and kill-session with tmux-kill-exit; screen -ls prints
            screen-ls.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes stand-in programs into a scratch folder.')]
        param([string]$TmuxSession = 'no', [int]$TmuxKillExit = 0, [string]$ScreenList = '', [int]$RmExit = 0)
        $base = Join-Path $script:ScratchBase ('m-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $bin = Join-Path $base 'bin'
        $rec = Join-Path $base 'rec'
        foreach ($dir in @($bin, $rec)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [System.IO.File]::WriteAllText((Join-Path $rec 'tmux-session'), $TmuxSession)
        [System.IO.File]::WriteAllText((Join-Path $rec 'screen-ls'), $ScreenList)
        $stub = @{
            sudo   = @'
#!/bin/sh
printf '%s\n' "$*" >> '@REC@/sudo.argv'
case "$*" in
    '-n /bin/rm -f /etc/sudoers.d/yuruna-host-update'|'-n /bin/rm -f /etc/sudoers.d/yuruna-host-update-access') exit @RM@ ;;
esac
exit 1
'@
            tmux   = @'
#!/bin/sh
printf '%s\n' "$*" >> '@REC@/tmux.argv'
case "$*" in
    *' has-session '*) [ "$(cat '@REC@/tmux-session')" = yes ] && exit 0; exit 1 ;;
    *' kill-session '*) [ @KILL@ -eq 0 ] && printf no > '@REC@/tmux-session'; exit @KILL@ ;;
esac
exit 1
'@
            screen = @'
#!/bin/sh
printf '%s\n' "$*" >> '@REC@/screen.argv'
if [ "$1" = -ls ]; then cat '@REC@/screen-ls'; exit 1; fi
exit 0
'@
        }
        foreach ($name in $stub.Keys) {
            $path = Join-Path $bin $name
            [System.IO.File]::WriteAllText($path, $stub[$name].Replace('@REC@', $rec).Replace('@RM@', "$RmExit").Replace('@KILL@', "$TmuxKillExit"))
            [System.IO.File]::SetUnixFileMode($path, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        return [pscustomobject]@{ Base = $base; Bin = $bin; Rec = $rec }
    }

    function Invoke-MacDisableStep {
        # -OnEnd runs in the child right after the controller session ended;
        # -Preview runs the removal under -WhatIf.
        param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)]$Stub, [string]$OnEnd = '', [switch]$Preview)
        $guard = Get-RegionSlice -Script 'Disable-TestAutomation.ps1' -Region 'Host update in progress' -NextRegion 'Read captured host settings' -HostDir $script:MacHostDir
        $removal = Get-RegionSlice -Script 'Disable-TestAutomation.ps1' -Region 'Host controller' -NextRegion 'pmset display/system/disk sleep, per power source' -HostDir $script:MacHostDir
        $hook = @'
function Stop-HostUpdateControllerSession {
    [CmdletBinding(SupportsShouldProcess)] param()
    $ended = Test.HostUpdate\Stop-HostUpdateControllerSession -Confirm:$false
    @ONEND@
    $ended
}
'@
        Invoke-Child -HomePath $HomePath -Stub $Stub -Text @(
            '[CmdletBinding(SupportsShouldProcess)] param()'
            "`$ErrorActionPreference = 'Stop'"
            "`$RepoRoot = '$($script:RepoRoot)'"
            '$restored = [System.Collections.Generic.List[string]]::new()'
            '$skipped = [System.Collections.Generic.List[string]]::new()'
            (Add-StandIn -Slice $guard)
            $(if ($OnEnd) { $hook.Replace('@ONEND@', $OnEnd) } else { '# no hook' })
            $(if ($Preview) { '$WhatIfPreference = $true' } else { '# no preview' })
            $removal
            'foreach ($line in $restored) { "RESTORED|$line" }'
            'foreach ($line in $skipped) { "SKIPPED|$line" }'
        )
    }

    function Get-ExpectedUnit {
        param([Parameter(Mandatory)][string]$HomePath)
        $shim = Join-Path $HomePath '.yuruna/host-repair/host-controller/shim'
        return (Get-HostUpdateControllerUnitText -TemplatePath $script:Template -Account 'runner' -ShimPath $shim)
    }

    function Add-ScratchHostUpdate {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: queues, and optionally claims, a host update in the scratch journal.')]
        param([Parameter(Mandatory)][string]$HomePath, [switch]$Claim)
        $id = New-YurunaHostOperationRequestId
        $admission = Request-HostUpdateAdmission -RequestId $id -Channel 'local' -RuntimeDir (Join-Path $HomePath 'runtime') -HostType 'host.ubuntu.kvm' -Confirm:$false
        if ($admission.Decision -ne 'queued') { throw "fixture sanity: admission answered $($admission.Decision) ($($admission.Reason))" }
        if ($Claim) {
            $start = & (Get-Module Test.HostOperationJournal) { Get-HostOperationProcessStartTime -ProcessId $PID }
            $lock = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostOperationLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
            try {
                $claimed = Confirm-HostUpdateClaim -RequestId $id -LifetimeLock $lock -ControllerPid $PID -ControllerStartTimeUnixMs $start `
                    -Snapshot '0123456789abcdef' -RepoRoot $script:RepoRoot -Mode claim -Confirm:$false
            } finally { Exit-YurunaSingleFlightLock -Lock $lock }
            if (-not $claimed.Accepted) { throw "fixture sanity: claim refused ($($claimed.Reason))" }
        }
        return $id
    }
}

AfterAll {
    # The listing is read while $HOME is still the scratch home, and the home
    # is left even when the comparison throws.
    try {
        foreach ($lock in @($script:HeldLocks)) { Exit-YurunaSingleFlightLock -Lock $lock }
        & (Get-Module Test.HostOperationJournal) { $script:HostOperationHomePath = $null }
        Remove-Item -LiteralPath Function:\Get-YurunaRunnerGateState -ErrorAction SilentlyContinue
        Assert-Equal -Expected $script:BypassRootBefore -Actual (Get-BypassRootState) "a call that bypassed its seam neither created nor changed the private root under the suite's home"
    } finally {
        Remove-YurunaTestTempDir -Path $script:ScratchBase
        Exit-YurunaTestHome $script:TestHome
    }
}

Describe 'the host controller unit' {
    It 'renders the eight design settings and no sandboxing option' {
        $text = Get-HostUpdateControllerUnitText -TemplatePath $script:Template -Account 'runner' -ShimPath '/home/runner/.yuruna/host-repair/host-controller/shim'
        $text | Should -Not -Match "`r" -Because 'systemd reads LF unit files'
        $text.EndsWith("`n") | Should -BeTrue
        $unit = ConvertFrom-UnitText -Text $text
        @($unit.Keys) | Should -Be @('Unit', 'Service', 'Install')
        $unit.Unit['StartLimitIntervalSec'] | Should -BeExactly '0' -Because 'StartLimitIntervalSec= belongs in [Unit]; in [Service] systemd ignores it'
        $unit.Service['Type'] | Should -BeExactly 'simple'
        $unit.Service['User'] | Should -BeExactly 'runner'
        $unit.Service['SupplementaryGroups'] | Should -BeExactly 'libvirt kvm'
        $unit.Service['ExecStart'] | Should -BeExactly '/bin/sh "/home/runner/.yuruna/host-repair/host-controller/shim"'
        $unit.Service['Restart'] | Should -BeExactly 'always'
        $unit.Service['RestartSec'] | Should -BeExactly '5'
        $unit.Service['KillMode'] | Should -BeExactly 'process' -Because 'a restart or stop of the unit must signal only the shim'
        $unit.Service['OOMPolicy'] | Should -BeExactly 'continue'
        $unit.Install['WantedBy'] | Should -BeExactly 'multi-user.target'
        foreach ($section in $unit.Values) {
            foreach ($name in @('PrivateTmp', 'ProtectHome', 'ProtectSystem', 'StartLimitBurst')) {
                $section.Contains($name) | Should -BeFalse -Because "the operator's shell must reach the console socket under the home folder ($name)"
            }
        }
        $text | Should -Not -Match '@(ACCOUNT|SHIM)@'
    }

    It 'quotes a shim path that contains a space in ExecStart' {
        $unit = ConvertFrom-UnitText -Text (Get-HostUpdateControllerUnitText -TemplatePath $script:Template -Account 'runner' -ShimPath '/home/test runner/.yuruna/host-repair/host-controller/shim')
        $unit.Service['ExecStart'] | Should -BeExactly '/bin/sh "/home/test runner/.yuruna/host-repair/host-controller/shim"'
        $odd = ConvertFrom-UnitText -Text (Get-HostUpdateControllerUnitText -TemplatePath $script:Template -Account 'runner' -ShimPath '/home/a"b\c%d$e/shim')
        $odd.Service['ExecStart'] | Should -BeExactly '/bin/sh "/home/a\"b\\c%%d$$e/shim"' -Because 'systemd reads a backslash, a quote, a percent and a dollar sign specially'
    }

    It 'refuses an account or a shim path that would break the unit' {
        { Get-HostUpdateControllerUnitText -TemplatePath $script:Template -Account 'run ner' -ShimPath '/home/x/shim' } | Should -Throw
        { Get-HostUpdateControllerUnitText -TemplatePath $script:Template -Account "runner`nUser=root" -ShimPath '/home/x/shim' } | Should -Throw
        { Get-HostUpdateControllerUnitText -TemplatePath $script:Template -Account 'runner' -ShimPath 'home/x/shim' } | Should -Throw
        { Get-HostUpdateControllerUnitText -TemplatePath $script:Template -Account 'runner' -ShimPath "/home/x`nExecStartPre=/bin/true" } | Should -Throw
    }
}

Describe 'the controller files Enable deploys' {
    BeforeAll {
        $script:FileHome = New-ScratchHome
        $script:FileCheckout = New-ScratchCheckout
        $script:FileRoot = Join-Path $script:FileHome '.yuruna/host-repair/host-controller'
    }

    It 'deploys the shim owner-only and a first snapshot with no previous' {
        $result = Install-HostUpdateControllerFile -RepoRoot $script:FileCheckout -Confirm:$false
        $result.Reason | Should -BeExactly 'installed'
        $result.ShimChanged | Should -BeTrue
        $result.CurrentWritten | Should -BeTrue
        $result.Snapshot | Should -BeExactly (Get-HostUpdateSnapshotManifest -SourceRoot $script:FileCheckout).Hash16
        $result.Shim | Should -BeExactly (Join-Path $script:FileRoot 'shim')
        [System.IO.File]::ReadAllBytes($result.Shim) | Should -Be ([System.IO.File]::ReadAllBytes((Join-Path $script:FileCheckout 'test/lab/yuruna-host-controller-shim.sh')))
        [System.IO.File]::GetUnixFileMode($result.Shim) | Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        $current = Read-HostUpdateControllerCurrent -ControllerRoot $script:FileRoot
        $current.Current | Should -BeExactly $result.Snapshot
        $current.Previous | Should -BeExactly '' -Because 'a first snapshot the shim rejects must not be started again as previous'
        $current.Checkout | Should -BeExactly $script:FileCheckout
        Test-Path -LiteralPath (Join-Path $script:FileRoot "versions/$($result.Snapshot)/automation/A.psm1") | Should -BeTrue
    }

    It 'changes nothing when run again' {
        $before = [System.IO.File]::ReadAllText((Join-Path $script:FileRoot 'current'))
        $result = Install-HostUpdateControllerFile -RepoRoot $script:FileCheckout -Confirm:$false
        $result.Reason | Should -BeExactly 'unchanged'
        $result.ShimChanged | Should -BeFalse
        $result.CurrentWritten | Should -BeFalse
        [System.IO.File]::ReadAllText((Join-Path $script:FileRoot 'current')) | Should -BeExactly $before
    }

    It 'keeps the snapshot it replaces as previous and removes older ones' {
        $first = (Read-HostUpdateControllerCurrent -ControllerRoot $script:FileRoot).Current
        Set-Content -LiteralPath (Join-Path $script:FileCheckout 'automation/A.psm1') -Value 'function Get-A { 3 }'
        $second = Install-HostUpdateControllerFile -RepoRoot $script:FileCheckout -Confirm:$false
        $second.CurrentWritten | Should -BeTrue
        $second.ShimChanged | Should -BeFalse
        (Read-HostUpdateControllerCurrent -ControllerRoot $script:FileRoot).Previous | Should -BeExactly $first
        Set-Content -LiteralPath (Join-Path $script:FileCheckout 'automation/A.psm1') -Value 'function Get-A { 4 }'
        $third = Install-HostUpdateControllerFile -RepoRoot $script:FileCheckout -Confirm:$false
        $current = Read-HostUpdateControllerCurrent -ControllerRoot $script:FileRoot
        $current.Current | Should -BeExactly $third.Snapshot
        $current.Previous | Should -BeExactly $second.Snapshot
        @(Get-ChildItem -LiteralPath (Join-Path $script:FileRoot 'versions') -Directory | ForEach-Object Name | Sort-Object) |
            Should -Be @(@($second.Snapshot, $third.Snapshot) | Sort-Object)
    }

    It 'writes the shim again when its bytes differ' {
        $shim = Join-Path $script:FileRoot 'shim'
        [System.IO.File]::WriteAllText($shim, "#!/bin/sh`nexit 0`n")
        $result = Install-HostUpdateControllerFile -RepoRoot $script:FileCheckout -Confirm:$false
        $result.ShimChanged | Should -BeTrue
        $result.Reason | Should -BeExactly 'installed'
        [System.IO.File]::ReadAllBytes($shim) | Should -Be ([System.IO.File]::ReadAllBytes((Join-Path $script:FileCheckout 'test/lab/yuruna-host-controller-shim.sh')))
    }

    It 'leaves current alone when the checkout snapshot was rejected' {
        $before = [System.IO.File]::ReadAllText((Join-Path $script:FileRoot 'current'))
        Set-Content -LiteralPath (Join-Path $script:FileCheckout 'automation/A.psm1') -Value 'function Get-A { 5 }'
        $hash = (Get-HostUpdateSnapshotManifest -SourceRoot $script:FileCheckout).Hash16
        [System.IO.File]::WriteAllText((Join-Path $script:FileRoot 'rejected'), "$hash`n")
        $result = Install-HostUpdateControllerFile -RepoRoot $script:FileCheckout -Confirm:$false
        $result.Reason | Should -BeExactly 'rejected'
        $result.Snapshot | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText((Join-Path $script:FileRoot 'current')) | Should -BeExactly $before
    }
}

Describe 'Enable registers the host controller unit' {
    It 'writes the unit only when its text differs and reloads once' {
        $homePath = New-ScratchHome
        $stub = New-StubBin
        $lock = Enter-ControllerLock
        try {
            $first = Invoke-EnableStep -HomePath $homePath -Stub $stub
            $first.Text | Should -Match '(?m)^UNMET\|$' -Because $first.Text
            $calls = @(Get-StubCall -Stub $stub)
            @($calls | Where-Object { $_ -ceq "-n tee $($stub.UnitPath)" }).Count | Should -Be 1
            @($calls | Where-Object { $_ -ceq '-n systemctl daemon-reload' }).Count | Should -Be 1
            [System.IO.File]::ReadAllText($stub.UnitPath) | Should -BeExactly (Get-ExpectedUnit -HomePath $homePath) -Because 'the file holds exactly the rendered text, with no newline added by the pipe'
            $first.Text | Should -Match 'MSG\|host\.host_controller_unit_installed'
            $first.Text | Should -Match 'MSG\|host\.host_controller_running\|snapshot=[0-9a-f]{16}'

            Clear-StubCall -Stub $stub
            $second = Invoke-EnableStep -HomePath $homePath -Stub $stub
            $second.Text | Should -Match '(?m)^UNMET\|$' -Because $second.Text
            $calls = @(Get-StubCall -Stub $stub)
            @($calls | Where-Object { $_ -match ' tee | daemon-reload' }).Count | Should -Be 0 -Because 'an unchanged unit is neither written nor reloaded'
            $second.Text | Should -Not -Match 'host_controller_unit_(installed|replaced)'

            Clear-StubCall -Stub $stub
            [System.IO.File]::AppendAllText($stub.UnitPath, "Environment=EDITED=1`n")
            $third = Invoke-EnableStep -HomePath $homePath -Stub $stub
            $calls = @(Get-StubCall -Stub $stub)
            @($calls | Where-Object { $_ -ceq "-n tee $($stub.UnitPath)" }).Count | Should -Be 1
            @($calls | Where-Object { $_ -ceq '-n systemctl daemon-reload' }).Count | Should -Be 1
            $third.Text | Should -Match 'MSG\|host\.host_controller_unit_replaced'
            [System.IO.File]::ReadAllText($stub.UnitPath) | Should -BeExactly (Get-ExpectedUnit -HomePath $homePath)
        } finally { Exit-ControllerLock -Lock $lock }
    }

    It 'restarts on a changed unit or shim, starts otherwise' {
        $homePath = New-ScratchHome
        $stub = New-StubBin
        $lock = Enter-ControllerLock
        try {
            $null = Invoke-EnableStep -HomePath $homePath -Stub $stub
            $calls = @(Get-StubCall -Stub $stub)
            $calls[-2..-1] | Should -Be @("-n systemctl enable $script:UnitName", "-n systemctl restart $script:UnitName")

            Clear-StubCall -Stub $stub
            $null = Invoke-EnableStep -HomePath $homePath -Stub $stub
            Get-StubCall -Stub $stub | Should -Be @("-n systemctl enable $script:UnitName", "-n systemctl start $script:UnitName")

            Clear-StubCall -Stub $stub
            [System.IO.File]::AppendAllText((Join-Path $homePath '.yuruna/host-repair/host-controller/shim'), "# edited`n")
            $null = Invoke-EnableStep -HomePath $homePath -Stub $stub
            Get-StubCall -Stub $stub | Should -Be @("-n systemctl enable $script:UnitName", "-n systemctl restart $script:UnitName") -Because 'a new shim runs only after the unit restarts it'
        } finally { Exit-ControllerLock -Lock $lock }
    }

    It 'only verifies and reports Unmet without sudo' {
        $homePath = New-ScratchHome
        $stub = New-StubBin -Enabled 'disabled' -Active 'inactive'
        $result = Invoke-EnableStep -HomePath $homePath -Stub $stub -CanSudo $false
        $result.Text | Should -Match 'MSG\|host\.host_controller_no_sudo'
        $result.Text | Should -Match "UNMET\|$([regex]::Escape($script:UnitName)) not registered"
        Get-StubCall -Stub $stub | Should -BeNullOrEmpty -Because 'without sudo nothing privileged is attempted'
        Get-StubCall -Stub $stub -Name 'systemctl' | Should -Be @("is-enabled $script:UnitName", "is-active $script:UnitName")

        # Registered, enabled and running with this checkout's unit: nothing
        # is unmet, and still nothing privileged runs.
        [System.IO.File]::WriteAllText($stub.UnitPath, (Get-ExpectedUnit -HomePath $homePath))
        [System.IO.File]::WriteAllText((Join-Path $stub.Rec 'is-enabled'), 'enabled')
        [System.IO.File]::WriteAllText((Join-Path $stub.Rec 'is-active'), 'active')
        $lock = Enter-ControllerLock
        try { $ready = Invoke-EnableStep -HomePath $homePath -Stub $stub -CanSudo $false } finally { Exit-ControllerLock -Lock $lock }
        $ready.Text | Should -Match '(?m)^UNMET\|$' -Because $ready.Text
        $ready.Text | Should -Match 'MSG\|host\.host_controller_running'
        Get-StubCall -Stub $stub | Should -BeNullOrEmpty
    }

    It 'only verifies under -NoOperatorPrompt and never writes, reloads, enables or restarts the unit, even with sudo' {
        # The enable phase of a host update runs under the controller this
        # unit starts; a restart would end the update walking it.
        $homePath = New-ScratchHome
        $stub = New-StubBin -Enabled 'enabled' -Active 'active'
        $lock = Enter-ControllerLock
        try { $null = Invoke-EnableStep -HomePath $homePath -Stub $stub } finally { Exit-ControllerLock -Lock $lock }
        [System.IO.File]::ReadAllText($stub.UnitPath) | Should -BeExactly (Get-ExpectedUnit -HomePath $homePath) -Because 'fixture sanity: the attended run deployed the unit'

        Clear-StubCall -Stub $stub
        $ready = Invoke-EnableStep -HomePath $homePath -Stub $stub -NoOperatorPrompt $true
        $ready.Text | Should -Match '(?m)^UNMET\|$' -Because $ready.Text
        $ready.Text | Should -Not -Match 'host_controller_not_verified'
        Get-StubCall -Stub $stub | Should -BeNullOrEmpty -Because 'a matching deployment is left as it runs'
        Get-StubCall -Stub $stub -Name 'systemctl' | Should -Be @("is-enabled $script:UnitName")

        Clear-StubCall -Stub $stub
        [System.IO.File]::AppendAllText($stub.UnitPath, "Environment=EDITED=1`n")
        $edited = [System.IO.File]::ReadAllText($stub.UnitPath)
        $differs = Invoke-EnableStep -HomePath $homePath -Stub $stub -CanSudo $true -NoOperatorPrompt $true
        @(Get-StubCall -Stub $stub | Where-Object { $_ -match ' tee |daemon-reload|systemctl (enable|start|restart) ' }).Count | Should -Be 0 -Because $differs.Text
        Get-StubCall -Stub $stub | Should -BeNullOrEmpty -Because 'nothing privileged runs under the switch'
        @(Get-StubCall -Stub $stub -Name 'systemctl' | Where-Object { $_ -match '^(daemon-reload|enable|start|restart)( |$)' }).Count | Should -Be 0
        [System.IO.File]::ReadAllText($stub.UnitPath) | Should -BeExactly $edited -Because 'a differing unit is reported, not replaced'
        $differs.Text | Should -Match 'MSG\|host\.host_controller_not_verified\|reason=definition-differs'
        $differs.Text | Should -Match '(?m)^UNMET\|host controller differs from this checkout$'
        $differs.Text | Should -Not -Match 'host_controller_unit_(installed|replaced)|host_controller_running'
    }

    It 'registers nothing when current could not be written, though the snapshot was staged' {
        # Install-HostUpdateControllerFile names the snapshot before it
        # writes current, so only its reason tells a deployment the shim can
        # start. A folder where current belongs makes that write fail.
        $homePath = New-ScratchHome
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $current = Join-Path $homePath '.yuruna/host-repair/host-controller/current'
        [System.IO.File]::Delete($current)
        $null = New-Item -ItemType Directory -Path $current
        $stub = New-StubBin
        $lock = Enter-ControllerLock
        try { $result = Invoke-EnableStep -HomePath $homePath -Stub $stub } finally { Exit-ControllerLock -Lock $lock }
        $result.Text | Should -Match 'MSG\|host\.host_controller_files_failed\|reason=current-io-error' -Because $result.Text
        $result.Text | Should -Match '(?m)^UNMET\|host controller not registered$'
        $result.Text | Should -Not -Match 'host_controller_unit_(installed|replaced)|host_controller_running'
        Get-StubCall -Stub $stub | Should -BeNullOrEmpty -Because 'no unit is written, enabled or started for a deployment the shim cannot start'
    }

    It 'reports Unmet when a group is missing' {
        $homePath = New-ScratchHome
        $stub = New-StubBin -Group @('libvirt')
        $result = Invoke-EnableStep -HomePath $homePath -Stub $stub
        $result.Text | Should -Match 'MSG\|host\.host_controller_group_missing\|grp=kvm'
        $result.Text | Should -Not -Match 'grp=libvirt'
        $result.Text | Should -Match 'UNMET\|host controller not registered'
        Get-StubCall -Stub $stub | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeFalse -Because 'a unit that cannot start gets no shim either'
    }

    It 'reports Unmet when the controller does not take its lock' {
        $homePath = New-ScratchHome
        $stub = New-StubBin
        $result = Invoke-EnableStep -HomePath $homePath -Stub $stub
        $result.Text | Should -Match 'MSG\|host\.host_controller_not_running'
        $result.Text | Should -Match 'UNMET\|host controller not running'
        $result.Text | Should -Not -Match 'MSG\|host\.host_controller_running'
    }

    It 'reports Unmet and starts nothing when a privileged step fails' {
        $homePath = New-ScratchHome
        $stub = New-StubBin -FailOn "-n systemctl enable $script:UnitName"
        $result = Invoke-EnableStep -HomePath $homePath -Stub $stub
        $result.Text | Should -Match 'MSG\|host\.host_controller_sudo_failed'
        $result.Text | Should -Match "UNMET\|$([regex]::Escape($script:UnitName)) not registered"
        @(Get-StubCall -Stub $stub | Where-Object { $_ -match 'systemctl (start|restart)' }).Count | Should -Be 0
    }

    It 'uses sudo -n for every privileged call' {
        $homePath = New-ScratchHome
        $stub = New-StubBin
        $lock = Enter-ControllerLock
        try { $null = Invoke-EnableStep -HomePath $homePath -Stub $stub } finally { Exit-ControllerLock -Lock $lock }
        $calls = @(Get-StubCall -Stub $stub)
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) { $call | Should -Match '^-n ' -Because "a password prompt from '$call' would stall an Enable whose output is captured" }
        # Structurally too: the region names no sudo of its own, and the one
        # helper it elevates through passes -n on every path.
        $region = [System.Management.Automation.Language.Parser]::ParseInput((Get-RegionSlice -Script 'Enable-TestAutomation.ps1' -Region 'Host controller' -NextRegion 'Outcome'), [ref]$null, [ref]$null)
        Get-YurunaTestCommandCallCount -Ast $region -Name 'sudo' | Should -Be 0
        $helper = Get-YurunaTestFunctionAst -Path (Join-Path $script:KvmHostDir 'Enable-TestAutomation.ps1') -Name 'Invoke-HostSudo'
        $sudo = @($helper.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'sudo' }, $true))
        $sudo.Count | Should -BeGreaterThan 0
        foreach ($call in $sudo) { $call.CommandElements[1].Extent.Text | Should -BeExactly '-n' }
    }
}

Describe 'Disable removes the host controller' {
    BeforeAll {
        # Run inside the child: a controller claims the queued update
        # between Disable's first check and the stop.
        $script:ClaimOnStop = @'
$queued = (Get-HostUpdateQueue).Queued
$lifetime = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostOperationLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
try {
    $claim = Confirm-HostUpdateClaim -RequestId $queued['requestId'] -LifetimeLock $lifetime -ControllerPid $PID -ControllerStartTimeUnixMs 1 -Snapshot '0123456789abcdef' -RepoRoot $RepoRoot -Mode claim -Confirm:$false
    if (-not $claim.Accepted) { throw "fixture sanity: claim refused ($($claim.Reason))" }
} finally { Exit-YurunaSingleFlightLock -Lock $lifetime }
'@
    }

    It 'refuses while a host update is claimed' {
        $homePath = New-ScratchHome
        $id = Add-ScratchHostUpdate -HomePath $homePath -Claim
        $stub = New-StubBin
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 1
        $result.Text | Should -Match "MSG\|host\.host_controller_update_claimed\|requestId=$id"
        Get-StubCall -Stub $stub | Should -BeNullOrEmpty -Because 'the refusal comes before any change'
        Test-Path -LiteralPath $stub.UnitPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'starts the controller again and refuses when it claimed an update while it was being stopped' {
        $homePath = New-ScratchHome
        $id = Add-ScratchHostUpdate -HomePath $homePath
        $stub = New-StubBin
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub -OnStop $script:ClaimOnStop
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match "MSG\|host\.host_controller_update_claimed\|requestId=$id"
        Get-StubCall -Stub $stub | Should -Be @("systemctl stop $script:UnitName", "systemctl start $script:UnitName") -Because 'the controller continues the claimed update'
        Test-Path -LiteralPath $stub.UnitPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'keeps the unit and the controller files and names the release when that start fails' {
        $homePath = New-ScratchHome
        $id = Add-ScratchHostUpdate -HomePath $homePath
        $stub = New-StubBin -FailOn "systemctl start $script:UnitName"
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub -OnStop $script:ClaimOnStop
        $result.ExitCode | Should -Be 0 -Because $result.Text
        $result.Text | Should -Match "SKIPPED\|MSG\|host\.host_controller_update_claimed_not_restarted\|detail=systemctl start $([regex]::Escape($script:UnitName)): stub output\|requestId=$id"
        $result.Text | Should -Not -Match 'RESTORED\|'
        Get-StubCall -Stub $stub | Should -Be @("systemctl stop $script:UnitName", "systemctl start $script:UnitName")
        Test-Path -LiteralPath $stub.UnitPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'refuses, stopping nothing, while the journal cannot tell whether a host update is claimed' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        [System.IO.File]::WriteAllText((Join-Path $homePath '.yuruna/host-repair/host-operation.journal'), 'not a journal')
        (Get-HostUpdateQueue).Status | Should -Be 'corrupt' -Because 'fixture sanity'
        $stub = New-StubBin
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'MSG\|host\.host_controller_update_unknown\|status=corrupt'
        Get-StubCall -Stub $stub | Should -BeNullOrEmpty -Because 'the refusal comes before any change'
        Test-Path -LiteralPath $stub.UnitPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'starts the controller again and refuses when the journal cannot be read after the stop' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        $journal = Join-Path $homePath '.yuruna/host-repair/host-operation.journal'
        $stub = New-StubBin
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub -OnStop "[IO.File]::WriteAllText('$journal', 'not a journal')"
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'MSG\|host\.host_controller_update_unknown\|status=corrupt'
        Get-StubCall -Stub $stub | Should -Be @("systemctl stop $script:UnitName", "systemctl start $script:UnitName") -Because 'a controller may hold an update the journal hides'
        Test-Path -LiteralPath $stub.UnitPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'keeps the unit, the controller files and the rule when that start fails while the journal cannot be read' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        $journal = Join-Path $homePath '.yuruna/host-repair/host-operation.journal'
        $stub = New-StubBin -FailOn "systemctl start $script:UnitName"
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub -OnStop "[IO.File]::WriteAllText('$journal', 'not a journal')"
        $result.ExitCode | Should -Be 0 -Because $result.Text
        $result.Text | Should -Match "SKIPPED\|MSG\|host\.host_controller_update_unknown_not_restarted\|detail=systemctl start $([regex]::Escape($script:UnitName)): stub output\|status=corrupt"
        $result.Text | Should -Not -Match 'RESTORED\|'
        Get-StubCall -Stub $stub | Should -Be @("systemctl stop $script:UnitName", "systemctl start $script:UnitName") -Because 'neither the unit nor a sudo rule an update may need is removed'
        Test-Path -LiteralPath $stub.UnitPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'goes on with only a queued host update' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        $stub = New-StubBin
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 0 -Because $result.Text
        $result.Text | Should -Not -Match 'host_controller_update_claimed'
        $result.Text | Should -Match 'RESTORED\|MSG\|host\.host_controller_unit_removed'
    }

    It 'stops, waits for the lock, removes unit and controller root and lists the removals in the report' {
        $homePath = New-ScratchHome
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $root = Join-Path $homePath '.yuruna/host-repair/host-controller'
        $stub = New-StubBin
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 0 -Because $result.Text
        Get-StubCall -Stub $stub | Should -Be @(
            "systemctl stop $script:UnitName", "systemctl disable $script:UnitName", "rm -f $($stub.UnitPath)", 'systemctl daemon-reload',
            '-n rm -f /etc/sudoers.d/yuruna-host-update', '-n systemctl stop yuruna-host-update-expire.timer') -Because 'a sudo rule a host update left goes once the controller is gone'
        Test-Path -LiteralPath $stub.UnitPath | Should -BeFalse
        Test-Path -LiteralPath $root | Should -BeFalse
        $result.Text | Should -Match 'RESTORED\|MSG\|host\.host_controller_unit_removed'
        $result.Text | Should -Match "RESTORED\|MSG\|host\.host_controller_files_removed\|path=$([regex]::Escape($root))"
        $result.Text | Should -Not -Match 'SKIPPED\|'
    }

    It 'keeps the controller files while a controller still holds its lock' {
        $homePath = New-ScratchHome
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $root = Join-Path $homePath '.yuruna/host-repair/host-controller'
        $stub = New-StubBin
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $lock = Enter-ControllerLock
        try { $result = Invoke-DisableStep -HomePath $homePath -Stub $stub } finally { Exit-ControllerLock -Lock $lock }
        Test-Path -LiteralPath (Join-Path $root 'shim') | Should -BeTrue
        $result.Text | Should -Match "SKIPPED\|MSG\|host\.host_controller_files_kept\|path=$([regex]::Escape($root))"
        $result.Text | Should -Match 'RESTORED\|MSG\|host\.host_controller_unit_removed' -Because 'the unit goes, so the controller does not come back at boot'
    }

    It 'reports a unit it could not stop and removes nothing after the failed step' {
        $homePath = New-ScratchHome
        $stub = New-StubBin -FailOn "systemctl stop $script:UnitName"
        [System.IO.File]::WriteAllText($stub.UnitPath, 'installed')
        $result = Invoke-DisableStep -HomePath $homePath -Stub $stub
        Get-StubCall -Stub $stub | Should -Be @("systemctl stop $script:UnitName")
        Test-Path -LiteralPath $stub.UnitPath | Should -BeTrue
        $result.Text | Should -Match "SKIPPED\|MSG\|host\.host_controller_unit_not_removed\|detail=systemctl stop $([regex]::Escape($script:UnitName))"
    }
}

# The Windows registration: the task definition Enable renders, and the two
# functions that register and remove the task, driven with fake Task
# Scheduler calls. Nothing here talks to a real scheduler; the cmdlets exist
# only on Windows.
Describe 'the host controller task on Windows' {
    BeforeAll {
        $script:TaskTemplate = Join-Path $script:RepoRoot 'host/windows.hyper-v/host-controller/yuruna-host-controller.task.xml'
        $script:Sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $script:Ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

        function New-FakeTaskService {
            # A scheduler with one task (or none) whose calls are recorded.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory fake scheduler.')]
            param([string]$State = '', [string[]]$Lock = @('held'), [string]$FailOn = '', [hashtable]$Claimed = $null, [string]$Status = 'ok')
            $fake = @{ Calls = [System.Collections.Generic.List[string]]::new(); State = $State; Lock = [System.Collections.Generic.Queue[string]]::new()
                FailOn = $FailOn; Claimed = $Claimed; Status = $Status }
            foreach ($l in $Lock) { $fake.Lock.Enqueue($l) }
            $fake.Service = @{
                Get        = { param($Name) $fake.Calls.Add("get $Name"); if ($fake.State) { [pscustomobject]@{ State = $fake.State } } }.GetNewClosure()
                Register   = { param($Name, $Xml) $fake.Calls.Add("register $Name $($Xml.Length)"); if ($fake.FailOn -eq 'register') { throw 'Access is denied.' }; if (-not $fake.State) { $fake.State = 'Ready' } }.GetNewClosure()
                Start      = { param($Name) $fake.Calls.Add("start $Name"); if ($fake.FailOn -eq 'start') { throw 'start refused' }; $fake.State = 'Running' }.GetNewClosure()
                Stop       = { param($Name) $fake.Calls.Add("stop $Name"); if ($fake.FailOn -eq 'stop') { throw 'stop refused' }; $fake.State = 'Ready' }.GetNewClosure()
                Unregister = { param($Name) $fake.Calls.Add("unregister $Name"); if ($fake.FailOn -eq 'unregister') { throw 'in use' }; $fake.State = '' }.GetNewClosure()
                LockState  = { if ($fake.Lock.Count -gt 1) { $fake.Lock.Dequeue() } else { $fake.Lock.Peek() } }.GetNewClosure()
                Sleep      = { param($Milliseconds) $null = $Milliseconds }
                Queue      = { [pscustomobject]@{ Status = $fake.Status; Claimed = $fake.Claimed; Queued = $null } }.GetNewClosure()
            }
            return $fake
        }

        function New-TaskRoot {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a scratch controller root.')]
            param()
            $dir = Join-Path $script:ScratchBase ('t-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $null = New-Item -ItemType Directory -Path $dir -Force
            return $dir
        }
    }

    It 'renders the design settings: logon trigger, highest privileges, normal priority, no limit, one instance, restart every minute' {
        $xml = [xml](Get-HostUpdateControllerTaskXml -TemplatePath $script:TaskTemplate -AccountSid $script:Sid -PowerShellPath $script:Ps -ShimPath 'C:\ProgramData\yuruna\host-controller\shim.ps1')
        $task = $xml.Task
        Assert-Equal -Expected $script:Sid -Actual $task.Triggers.LogonTrigger.UserId
        Assert-Equal -Expected $script:Sid -Actual $task.Principals.Principal.UserId
        Assert-Equal -Expected 'InteractiveToken' -Actual $task.Principals.Principal.LogonType 'run only when the account is logged on'
        Assert-Equal -Expected 'HighestAvailable' -Actual $task.Principals.Principal.RunLevel
        $settings = $task.Settings
        Assert-Equal -Expected '4' -Actual $settings.Priority 'normal priority, inherited by the listener and the runner'
        Assert-Equal -Expected 'PT0S' -Actual $settings.ExecutionTimeLimit
        Assert-Equal -Expected 'IgnoreNew' -Actual $settings.MultipleInstancesPolicy
        Assert-Equal -Expected 'false' -Actual $settings.DisallowStartIfOnBatteries
        Assert-Equal -Expected 'false' -Actual $settings.StopIfGoingOnBatteries
        Assert-Equal -Expected 'PT1M' -Actual $settings.RestartOnFailure.Interval
        Assert-Equal -Expected '999' -Actual $settings.RestartOnFailure.Count 'the largest count the scheduler accepts'
        Assert-Equal -Expected $script:Ps -Actual $task.Actions.Exec.Command
        Assert-Equal -Expected '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\yuruna\host-controller\shim.ps1"' -Actual $task.Actions.Exec.Arguments
        Assert-Equal -Expected 'C:\ProgramData\yuruna\host-controller' -Actual $task.Actions.Exec.WorkingDirectory
    }

    It 'escapes a path that XML reads specially and refuses values that would break the task' {
        $xml = [xml](Get-HostUpdateControllerTaskXml -TemplatePath $script:TaskTemplate -AccountSid $script:Sid -PowerShellPath $script:Ps -ShimPath 'C:\Data <a> & b\shim.ps1')
        Assert-Equal -Expected 'C:\Data <a> & b' -Actual $xml.Task.Actions.Exec.WorkingDirectory
        foreach ($bad in @(@{ AccountSid = 'runner' }, @{ PowerShellPath = 'powershell.exe' }, @{ ShimPath = 'C:\a"b\shim.ps1' }, @{ ShimPath = '/home/runner/shim.ps1' })) {
            $arguments = @{ TemplatePath = $script:TaskTemplate; AccountSid = $script:Sid; PowerShellPath = $script:Ps; ShimPath = 'C:\x\shim.ps1' }
            foreach ($k in $bad.Keys) { $arguments[$k] = $bad[$k] }
            $threw = $false
            try { $null = Get-HostUpdateControllerTaskXml @arguments } catch { $threw = $true }
            Assert-True $threw "refused $($bad.Keys) = $($bad.Values)"
        }
    }

    It 'registers a new task, starts it and waits for the lock' {
        $root = New-TaskRoot
        $fake = New-FakeTaskService -Lock @('free', 'free', 'held')
        $r = Register-HostUpdateControllerTask -TaskName 'T' -Definition '<Task/>' -DefinitionPath (Join-Path $root 'task.xml') -StopPath (Join-Path $root 'stop') -Service $fake.Service -Confirm:$false
        Assert-Equal -Expected 'running|registered' -Actual "$($r.Outcome)|$($r.Change)"
        Assert-Equal -Expected 'get T,register T 7,get T,start T' -Actual ($fake.Calls -join ',')
        Assert-Equal -Expected '<Task/>' -Actual ([IO.File]::ReadAllText((Join-Path $root 'task.xml')))
    }

    It 'changes nothing for the same definition and a running task' {
        $root = New-TaskRoot
        [IO.File]::WriteAllText((Join-Path $root 'task.xml'), '<Task/>')
        $fake = New-FakeTaskService -State 'Running'
        $r = Register-HostUpdateControllerTask -TaskName 'T' -Definition '<Task/>' -DefinitionPath (Join-Path $root 'task.xml') -StopPath (Join-Path $root 'stop') -Service $fake.Service -Confirm:$false
        Assert-Equal -Expected 'running|none' -Actual "$($r.Outcome)|$($r.Change)"
        Assert-Equal -Expected 'get T,get T' -Actual ($fake.Calls -join ',')
    }

    It 'restarts a running task through the stop file when <Case>' -ForEach @(
        @{ Case = 'the definition changed'; Recorded = '<Old/>'; Shim = $false; Change = 'replaced' }
        @{ Case = 'the shim changed'; Recorded = '<Task/>'; Shim = $true; Change = 'none' }
    ) {
        $root = New-TaskRoot
        [IO.File]::WriteAllText((Join-Path $root 'task.xml'), $Recorded)
        $stop = Join-Path $root 'stop'
        $fake = New-FakeTaskService -State 'Running' -Lock @('held', 'free', 'held')
        $fake.Service.Stop = { param($Name) $fake.Calls.Add("stop $Name stopfile=$([IO.File]::Exists($stop))"); $fake.State = 'Ready' }.GetNewClosure()
        $r = Register-HostUpdateControllerTask -TaskName 'T' -Definition '<Task/>' -DefinitionPath (Join-Path $root 'task.xml') -StopPath $stop -ShimChanged $Shim -Service $fake.Service -Confirm:$false
        Assert-Equal -Expected "running|$Change" -Actual "$($r.Outcome)|$($r.Change)"
        Assert-True ($fake.Calls -contains 'stop T stopfile=True') 'the task is stopped only after the shim was asked to stop'
        Assert-Equal -Expected 'start T' -Actual $fake.Calls[-1]
        Assert-False ([IO.File]::Exists($stop)) 'the stop file is gone before the start'
    }

    It 'reports <Outcome> when <Case>' -ForEach @(
        @{ Case = 'the controller never takes its lock'; FailOn = ''; Lock = @('free'); Outcome = 'not-running' }
        @{ Case = 'the registration fails'; FailOn = 'register'; Lock = @('held'); Outcome = 'failed' }
        @{ Case = 'the start fails'; FailOn = 'start'; Lock = @('held'); Outcome = 'failed' }
    ) {
        $root = New-TaskRoot
        $fake = New-FakeTaskService -Lock $Lock -FailOn $FailOn
        $r = Register-HostUpdateControllerTask -TaskName 'T' -Definition '<Task/>' -DefinitionPath (Join-Path $root 'task.xml') -StopPath (Join-Path $root 'stop') -Service $fake.Service -Confirm:$false
        Assert-Equal -Expected $Outcome -Actual $r.Outcome
        if ($FailOn) { Assert-True ([string]$r.Detail -ne '') 'the failure names its cause' }
    }

    It 'changes nothing under -WhatIf' {
        $root = New-TaskRoot
        $fake = New-FakeTaskService
        $r = Register-HostUpdateControllerTask -TaskName 'T' -Definition '<Task/>' -DefinitionPath (Join-Path $root 'task.xml') -StopPath (Join-Path $root 'stop') -Service $fake.Service -WhatIf
        Assert-Equal -Expected 'not-running|preview' -Actual "$($r.Outcome)|$($r.Detail)"
        Assert-Equal -Expected 0 -Actual $fake.Calls.Count
    }

    It 'stops through the stop file and removes the task when the journal reads <Status>' -ForEach @(
        @{ Status = 'ok' }, @{ Status = 'absent' }, @{ Status = 'recovered-previous' }
    ) {
        $root = New-TaskRoot
        $stop = Join-Path $root 'stop'
        $fake = New-FakeTaskService -State 'Running' -Lock @('held', 'free') -Status $Status
        $fake.Service.Stop = { param($Name) $fake.Calls.Add("stop $Name stopfile=$([IO.File]::Exists($stop))"); $fake.State = 'Ready' }.GetNewClosure()
        $r = Unregister-HostUpdateControllerTask -TaskName 'T' -StopPath $stop -Service $fake.Service -Confirm:$false
        Assert-Equal -Expected 'removed' -Actual $r.Outcome
        Assert-Equal -Expected 'get T,stop T stopfile=True,unregister T' -Actual ($fake.Calls -join ',')
    }

    It 'starts the task again and removes nothing when the controller claimed an update during the stop' {
        $root = New-TaskRoot
        $stop = Join-Path $root 'stop'
        $fake = New-FakeTaskService -State 'Running' -Lock @('free') -Claimed @{ requestId = '0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90' }
        $r = Unregister-HostUpdateControllerTask -TaskName 'T' -StopPath $stop -Service $fake.Service -Confirm:$false
        Assert-Equal -Expected 'claimed|0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90' -Actual "$($r.Outcome)|$($r.RequestId)"
        Assert-False ($fake.Calls -contains 'unregister T')
        Assert-Equal -Expected 'start T' -Actual $fake.Calls[-1]
        Assert-False ([IO.File]::Exists($stop)) 'the restarted shim finds no stop file'
        $failing = New-FakeTaskService -State 'Running' -Lock @('free') -FailOn 'start' -Claimed @{ requestId = '0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90' }
        $r = Unregister-HostUpdateControllerTask -TaskName 'T' -StopPath $stop -Service $failing.Service -Confirm:$false
        Assert-Equal -Expected 'claimed-not-restarted' -Actual $r.Outcome
        Assert-Match -Pattern 'Start-ScheduledTask' -Actual $r.Detail
    }

    It 'starts the task again and removes nothing when the journal cannot be read once the task stopped' {
        $root = New-TaskRoot
        $stop = Join-Path $root 'stop'
        $fake = New-FakeTaskService -State 'Running' -Lock @('free') -Status 'unreadable'
        $r = Unregister-HostUpdateControllerTask -TaskName 'T' -StopPath $stop -Service $fake.Service -Confirm:$false
        Assert-Equal -Expected 'unknown|unreadable' -Actual "$($r.Outcome)|$($r.Status)" 'an unreadable journal can hide an update claimed during the stop'
        Assert-False ($fake.Calls -contains 'unregister T')
        Assert-Equal -Expected 'start T' -Actual $fake.Calls[-1]
        Assert-False ([IO.File]::Exists($stop)) 'the restarted shim finds no stop file'
        $failing = New-FakeTaskService -State 'Running' -Lock @('free') -FailOn 'start' -Status 'corrupt'
        $r = Unregister-HostUpdateControllerTask -TaskName 'T' -StopPath $stop -Service $failing.Service -Confirm:$false
        Assert-Equal -Expected 'unknown-not-restarted|corrupt' -Actual "$($r.Outcome)|$($r.Status)"
        Assert-Match -Pattern 'Start-ScheduledTask' -Actual $r.Detail
        Assert-False ($failing.Calls -contains 'unregister T')
    }

    It 'answers <Outcome> for <Case>' -ForEach @(
        @{ Case = 'no task'; State = ''; FailOn = ''; Outcome = 'absent' }
        @{ Case = 'a stop that fails'; State = 'Running'; FailOn = 'stop'; Outcome = 'failed' }
        @{ Case = 'an unregistration that fails'; State = 'Ready'; FailOn = 'unregister'; Outcome = 'failed' }
    ) {
        $fake = New-FakeTaskService -State $State -Lock @('free') -FailOn $FailOn
        $r = Unregister-HostUpdateControllerTask -TaskName 'T' -StopPath '' -Service $fake.Service -Confirm:$false
        Assert-Equal -Expected $Outcome -Actual $r.Outcome
        if ($Outcome -eq 'failed') { Assert-False ($fake.Calls -contains 'unregister T' -and $FailOn -eq 'stop') 'nothing is unregistered after a failed stop' }
    }

    It 'is what the Windows scripts call' {
        $enable = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/windows.hyper-v/Enable-TestAutomation.ps1'))
        $disable = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/windows.hyper-v/Disable-TestAutomation.ps1'))
        Assert-Match -Pattern 'Register-HostUpdateControllerTask -TaskName \$controllerTask' -Actual $enable
        Assert-Match -Pattern 'Get-HostUpdateControllerTaskXml -TemplatePath' -Actual $enable
        Assert-Match -Pattern 'Unregister-HostUpdateControllerTask -TaskName \$controllerTask' -Actual $disable
        Assert-Match -Pattern '(?s)REGION: Host update in progress.*Get-HostUpdateQueue.*REGION: Read captured host settings' -Actual $disable
        Assert-False ($enable -match 'Register-ScheduledTask|Start-ScheduledTask') 'the scripts reach the scheduler only through the tested functions'
    }
}

# The Windows scripts' own reading of the deployment and of the journal: their
# regions run in a child pwsh as on KVM, with the module's paths under the
# scratch home. The scheduler is reached only through stand-ins that print a
# line, so nothing here registers or stops a task.
Describe 'the Windows scripts around the host controller' {
    BeforeAll {
        $script:TaskStandIn = @'
function Get-HostUpdateControllerTaskXml { [Console]::Out.WriteLine('CALL|Get-HostUpdateControllerTaskXml'); '<Task/>' }
function Register-HostUpdateControllerTask { [Console]::Out.WriteLine('CALL|Register-HostUpdateControllerTask'); [pscustomobject]@{ Change = 'none'; Outcome = 'running'; Detail = '' } }
'@
        function Invoke-WindowsEnableStep {
            param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)]$Stub)
            $slice = Get-RegionSlice -Script 'Enable-TestAutomation.ps1' -Region 'Host controller' -NextRegion 'Outcome' -HostDir $script:WindowsHostDir
            Invoke-Child -HomePath $HomePath -Stub $Stub -Text @(
                "`$ErrorActionPreference = 'Stop'"
                "`$RepoRoot = '$($script:RepoRoot)'"
                '$NoOperatorPrompt = $false'
                '$unmetCount = 0'
                (Add-StandIn -Slice $slice -Extra $script:TaskStandIn)
                '"UNMET|$unmetCount"'
            )
        }
        function Invoke-WindowsDisableRemoval {
            # The removal region after the guard, with the task removal a
            # stand-in that answers -Outcome; the controller root is the
            # scratch home's.
            param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)]$Stub, [Parameter(Mandatory)][string]$Outcome)
            $guard = Get-RegionSlice -Script 'Disable-TestAutomation.ps1' -Region 'Host update in progress' -NextRegion 'Read captured host settings' -HostDir $script:WindowsHostDir
            $removal = Get-RegionSlice -Script 'Disable-TestAutomation.ps1' -Region 'Host controller' -NextRegion 'Power settings' -HostDir $script:WindowsHostDir
            $unregister = @"
function Unregister-HostUpdateControllerTask {
    [CmdletBinding(SupportsShouldProcess)] param([string]`$TaskName, [string]`$StopPath)
    [pscustomobject]@{ Outcome = '$Outcome'; RequestId = ''; Status = 'unreadable'; Detail = 'Start-ScheduledTask: Access is denied.' }
}
"@
            Invoke-Child -HomePath $HomePath -Stub $Stub -Text @(
                '[CmdletBinding(SupportsShouldProcess)] param()'
                "`$ErrorActionPreference = 'Stop'"
                "`$RepoRoot = '$($script:RepoRoot)'"
                '$restored = [System.Collections.Generic.List[string]]::new()'
                '$skipped = [System.Collections.Generic.List[string]]::new()'
                (Add-StandIn -Slice $guard -Extra $unregister)
                $removal
                'foreach ($line in $restored) { "RESTORED|$line" }'
                'foreach ($line in $skipped) { "SKIPPED|$line" }'
            )
        }
        function Invoke-WindowsDisableGuard {
            param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)]$Stub)
            $guard = Get-RegionSlice -Script 'Disable-TestAutomation.ps1' -Region 'Host update in progress' -NextRegion 'Read captured host settings' -HostDir $script:WindowsHostDir
            Invoke-Child -HomePath $HomePath -Stub $Stub -Text @(
                "`$ErrorActionPreference = 'Stop'"
                "`$RepoRoot = '$($script:RepoRoot)'"
                (Add-StandIn -Slice $guard)
                '"PASSED"'
            )
        }
    }

    It 'Enable registers no task when current could not be written, though the snapshot was staged' {
        $homePath = New-ScratchHome
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $current = Join-Path $homePath '.yuruna/host-repair/host-controller/current'
        [System.IO.File]::Delete($current)
        $null = New-Item -ItemType Directory -Path $current
        $result = Invoke-WindowsEnableStep -HomePath $homePath -Stub (New-StubBin)
        $result.Text | Should -Match 'MSG\|host\.host_controller_task_files_failed\|reason=current-io-error' -Because $result.Text
        $result.Text | Should -Match '(?m)^UNMET\|1$'
        $result.Text | Should -Not -Match 'CALL\|' -Because 'no task is rendered or registered for a deployment the shim cannot start'
    }

    It 'Disable goes on with only a queued host update' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        $result = Invoke-WindowsDisableGuard -HomePath $homePath -Stub (New-StubBin)
        $result.ExitCode | Should -Be 0 -Because $result.Text
        $result.Text | Should -Match '(?m)^PASSED$'
    }

    It 'Disable refuses while a host update is claimed' {
        $homePath = New-ScratchHome
        $id = Add-ScratchHostUpdate -HomePath $homePath -Claim
        $result = Invoke-WindowsDisableGuard -HomePath $homePath -Stub (New-StubBin)
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match "MSG\|host\.host_controller_update_claimed\|requestId=$id"
        $result.Text | Should -Not -Match '(?m)^PASSED$'
    }

    It 'Disable refuses, changing nothing, while the journal cannot tell whether a host update is claimed' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        [System.IO.File]::WriteAllText((Join-Path $homePath '.yuruna/host-repair/host-operation.journal'), 'not a journal')
        (Get-HostUpdateQueue).Status | Should -Be 'corrupt' -Because 'fixture sanity'
        $result = Invoke-WindowsDisableGuard -HomePath $homePath -Stub (New-StubBin)
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'MSG\|host\.host_controller_update_unknown\|status=corrupt'
        $result.Text | Should -Not -Match '(?m)^PASSED$'
    }

    It 'Disable refuses and keeps the controller files when the journal cannot be read once the task stopped' {
        $homePath = New-ScratchHome
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $result = Invoke-WindowsDisableRemoval -HomePath $homePath -Stub (New-StubBin) -Outcome 'unknown'
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'MSG\|host\.host_controller_update_unknown\|status=unreadable'
        $result.Text | Should -Not -Match 'RESTORED\|'
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'Disable keeps the controller files and names the start that failed when the journal cannot be read once the task stopped' {
        $homePath = New-ScratchHome
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $result = Invoke-WindowsDisableRemoval -HomePath $homePath -Stub (New-StubBin) -Outcome 'unknown-not-restarted'
        $result.ExitCode | Should -Be 0 -Because $result.Text
        $result.Text | Should -Match 'SKIPPED\|MSG\|host\.host_controller_task_unknown_not_restarted\|detail=Start-ScheduledTask: Access is denied\.\|status=unreadable'
        $result.Text | Should -Not -Match 'host_controller_files_removed'
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }
}

# macOS Disable, its regions run in a child pwsh as on KVM: the platform guard
# keeps the whole file off this host. tmux, screen and sudo are stand-ins on
# the child's PATH, and the private root is the scratch home's.
Describe 'Disable removes the host controller on macOS' {
    BeforeAll {
        $script:ClaimOnEnd = @'
$queued = (Get-HostUpdateQueue).Queued
$lifetime = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostOperationLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
try {
    $claim = Confirm-HostUpdateClaim -RequestId $queued['requestId'] -LifetimeLock $lifetime -ControllerPid $PID -ControllerStartTimeUnixMs 1 -Snapshot '0123456789abcdef' -RepoRoot $RepoRoot -Mode claim -Confirm:$false
    if (-not $claim.Accepted) { throw "fixture sanity: claim refused ($($claim.Reason))" }
} finally { Exit-YurunaSingleFlightLock -Lock $lifetime }
'@
        $script:Rule = '-n /bin/rm -f /etc/sudoers.d/yuruna-host-update'
        $script:Entry = '-n /bin/rm -f /etc/sudoers.d/yuruna-host-update-access'
        $script:TmuxHas = '-L yuruna-controller -f /dev/null has-session -t =yuruna-controller'
        $script:TmuxKill = '-L yuruna-controller -f /dev/null kill-session -t =yuruna-controller'
    }

    It 'refuses while a host update is claimed, before it ends anything' {
        $homePath = New-ScratchHome
        $id = Add-ScratchHostUpdate -HomePath $homePath -Claim
        $stub = New-MacStubBin -TmuxSession 'yes'
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match "MSG\|host\.host_controller_update_claimed\|requestId=$id"
        foreach ($name in @('sudo', 'tmux', 'screen')) { Get-StubCall -Stub $stub -Name $name | Should -BeNullOrEmpty -Because "$name is not reached" }
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'ends the tmux session and every screen session, then removes the files, the rule and the entry, with only a queued update' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $root = Join-Path $homePath '.yuruna/host-repair/host-controller'
        $listing = "There are screens on:`n`t4101.yuruna-controller`t(Detached)`n`t4102.yuruna-controller`t(Detached)`n`t4103.yuruna-controller`t(Dead ???)`n`t4104.other`t(Detached)`n4 Sockets in /tmp/screens/S-runner.`n"
        $stub = New-MacStubBin -TmuxSession 'yes' -ScreenList $listing
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 0 -Because $result.Text
        Get-StubCall -Stub $stub -Name 'tmux' | Should -Be @($script:TmuxHas, $script:TmuxKill)
        Get-StubCall -Stub $stub -Name 'screen' | Should -Be @('-ls', '-S 4101.yuruna-controller -X quit', '-S 4102.yuruna-controller -X quit') -Because 'each live session of that exact name, none by a bare name'
        Get-StubCall -Stub $stub -Name 'sudo' | Should -Be @($script:Rule, $script:Entry) -Because 'the one rm the entry allows, then the entry itself; no systemctl on macOS'
        Test-Path -LiteralPath $root | Should -BeFalse
        $result.Text | Should -Match 'RESTORED\|MSG\|host\.host_controller_session_ended'
        $result.Text | Should -Match "RESTORED\|MSG\|host\.host_controller_files_removed\|path=$([regex]::Escape($root))"
        $result.Text | Should -Match 'RESTORED\|MSG\|host\.host_update_access_entry_removed'
        $result.Text | Should -Not -Match 'SKIPPED\|'
        $result.Text | Should -Not -Match 'host_controller_update_claimed'
    }

    It 'removes the rule and the entry also with no session and no controller files' {
        $homePath = New-ScratchHome
        $stub = New-MacStubBin
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 0 -Because $result.Text
        Get-StubCall -Stub $stub -Name 'tmux' | Should -Be @($script:TmuxHas)
        Get-StubCall -Stub $stub -Name 'sudo' | Should -Be @($script:Rule, $script:Entry)
        $result.Text | Should -Not -Match 'host_controller_session_ended'
        $result.Text | Should -Match 'RESTORED\|MSG\|host\.host_update_access_entry_removed'
    }

    It 'refuses and keeps every file when the controller claimed an update while its session ended' {
        $homePath = New-ScratchHome
        $id = Add-ScratchHostUpdate -HomePath $homePath
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $stub = New-MacStubBin -TmuxSession 'yes'
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub -OnEnd $script:ClaimOnEnd
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match "MSG\|host\.host_controller_update_claimed_session_ended\|requestId=$id"
        Get-StubCall -Stub $stub -Name 'sudo' | Should -BeNullOrEmpty -Because 'the update may need the rule and the entry'
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'refuses, ending nothing, while the journal cannot tell whether a host update is claimed' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        [IO.File]::WriteAllText((Join-Path $homePath '.yuruna/host-repair/host-operation.journal'), 'not a journal')
        (Get-HostUpdateQueue).Status | Should -Be 'corrupt' -Because 'fixture sanity'
        $stub = New-MacStubBin -TmuxSession 'yes'
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'MSG\|host\.host_controller_update_unknown\|status=corrupt'
        foreach ($name in @('sudo', 'tmux', 'screen')) { Get-StubCall -Stub $stub -Name $name | Should -BeNullOrEmpty -Because "$name is not reached" }
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'refuses and keeps every file when the journal cannot be read after the session ended' {
        $homePath = New-ScratchHome
        $null = Add-ScratchHostUpdate -HomePath $homePath
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $journal = Join-Path $homePath '.yuruna/host-repair/host-operation.journal'
        $stub = New-MacStubBin -TmuxSession 'yes'
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub -OnEnd "[IO.File]::WriteAllText('$journal', 'not a journal')"
        $result.ExitCode | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'MSG\|host\.host_controller_update_unknown_session_ended\|status=corrupt'
        Get-StubCall -Stub $stub -Name 'tmux' | Should -Be @($script:TmuxHas, $script:TmuxKill)
        Get-StubCall -Stub $stub -Name 'sudo' | Should -BeNullOrEmpty -Because 'an update the journal hides may need the rule and the entry'
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'keeps the files, the rule and the entry while a controller still holds its lock' {
        $homePath = New-ScratchHome
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $root = Join-Path $homePath '.yuruna/host-repair/host-controller'
        $stub = New-MacStubBin
        $lock = Enter-ControllerLock
        try { $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub } finally { Exit-ControllerLock -Lock $lock }
        $result.ExitCode | Should -Be 0 -Because $result.Text
        Test-Path -LiteralPath (Join-Path $root 'shim') | Should -BeTrue
        $result.Text | Should -Match "SKIPPED\|MSG\|host\.host_controller_files_kept\|path=$([regex]::Escape($root))"
        $result.Text | Should -Match 'SKIPPED\|MSG\|host\.host_update_access_entry_kept'
        Get-StubCall -Stub $stub -Name 'sudo' | Should -BeNullOrEmpty -Because 'a running controller could claim an update that needs them'
    }

    It 'keeps the rule and the entry when the session could not be ended' {
        $homePath = New-ScratchHome
        $stub = New-MacStubBin -TmuxSession 'yes' -TmuxKillExit 1
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 0 -Because $result.Text
        $result.Text | Should -Match 'SKIPPED\|MSG\|host\.host_controller_session_not_ended'
        $result.Text | Should -Match 'SKIPPED\|MSG\|host\.host_update_access_entry_kept'
        Get-StubCall -Stub $stub -Name 'sudo' | Should -BeNullOrEmpty
    }

    It 'lists a rule and an entry it could not remove' {
        $homePath = New-ScratchHome
        $stub = New-MacStubBin -RmExit 1
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub
        $result.ExitCode | Should -Be 0 -Because $result.Text
        Get-StubCall -Stub $stub -Name 'sudo' | Should -Be @($script:Rule, $script:Entry)
        $result.Text | Should -Match 'SKIPPED\|MSG\|host\.host_update_rule_not_removed'
        $result.Text | Should -Match 'SKIPPED\|MSG\|host\.host_update_access_entry_not_removed'
        $result.Text | Should -Not -Match 'RESTORED\|MSG\|host\.host_update_access_entry_removed'
    }

    It 'changes nothing under -WhatIf' {
        $homePath = New-ScratchHome
        $null = Install-HostUpdateControllerFile -RepoRoot (New-ScratchCheckout) -Confirm:$false
        $stub = New-MacStubBin -TmuxSession 'yes'
        $result = Invoke-MacDisableStep -HomePath $homePath -Stub $stub -Preview
        $result.ExitCode | Should -Be 0 -Because $result.Text
        foreach ($name in @('sudo', 'tmux', 'screen')) { Get-StubCall -Stub $stub -Name $name | Should -BeNullOrEmpty -Because "$name is not reached" }
        Test-Path -LiteralPath (Join-Path $homePath '.yuruna/host-repair/host-controller/shim') | Should -BeTrue
    }

    It 'primes sudo with or without a capture, since the entry does not allow its own removal' {
        $slice = Get-RegionSlice -Script 'Disable-TestAutomation.ps1' -Region 'Prime sudo' -NextRegion 'Host controller' -HostDir $script:MacHostDir
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($slice, [ref]$null, [ref]$null)
        $prime = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Initialize-SudoCache' }, $true))
        $prime.Count | Should -Be 1
        $guard = $prime[0].Parent
        while ($guard -and $guard -isnot [System.Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
        $guard.Clauses[0].Item1.Extent.Text | Should -Be '-not $WhatIfPreference'
        $prime[0].Extent.Text | Should -Match 'yuruna-host-update-access'
    }
}
