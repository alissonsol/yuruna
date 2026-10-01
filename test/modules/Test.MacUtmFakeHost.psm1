<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42d9bcb8-2e31-4e63-94f1-fc3ab0b50782
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos utm fake host shim pester
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
    Test support: a stand-in macOS/UTM host, so the macOS driver's native
    calls can be exercised on any POSIX host without UTM.
.DESCRIPTION
    New-MacUtmFakeHost writes small /bin/sh stand-ins for every tool the
    driver runs -- utmctl, osascript, pgrep, open, killall, kill, ps, id,
    PlistBuddy, plutil, qemu-img, arp, launchctl, ifconfig, sudo -- into a
    private directory. Each stand-in appends its argument vector to one call
    log and takes its behavior from small files in a state directory: a
    '<tool>.mode' file sets a fixed mode, and a '<tool>.queue' file (one
    mode per line) overrides it one call at a time, so a case can script
    "the first probe hangs, the second answers".

    The process table is a directory of rows (uid, name, start time,
    command, user, and 'real' for a row a stand-in registered for its own
    live process). Stand-ins never act on the real host: sudo only answers,
    kill only removes rows (and signals only processes a stand-in itself
    started), and pgrep refuses a match that is not scoped with -U.

    Enter-MacUtmFakeHost puts the stand-ins first on PATH, points the global
    $HOME at a private tree, and repoints the loaded macOS driver's tool
    table, utmctl bundle path, watchdog paths, lease path and poll knobs at
    the fake host; Exit-MacUtmFakeHost restores every one of them.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# The shell prologue every stand-in shares: log the call, then read modes
# from the state directory. A queued mode wins over the fixed one.
$script:MacUtmFakePrologue = @'
#!/bin/sh
S="$YRN_FAKE_STATE"
# Every file a stand-in reads, writes or removes is under the fake host's
# state or home directory; without them it refuses to run at all.
if [ -z "$S" ] || [ -z "$YRN_FAKE_LOG" ] || [ -z "$YRN_FAKE_HOME" ]; then echo "fake $YRN_TOOL: fake host is not entered" >&2; exit 97; fi
{ printf '%s' "$YRN_TOOL"; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$YRN_FAKE_LOG"
st() { if [ -f "$S/$1" ]; then cat "$S/$1"; fi; }
pop() {
  q="$S/$1"
  if [ -s "$q" ]; then head -n 1 "$q"; tail -n +2 "$q" > "$q.tmp"; mv "$q.tmp" "$q"; fi
}
mode() { m=$(pop "$1.queue"); if [ -z "$m" ]; then m=$(st "$1.mode"); fi; printf '%s' "$m"; }
next_pid() { n=$(st next.pid); [ -z "$n" ] && n=70000; n=$((n + 1)); echo "$n" > "$S/next.pid"; echo "$n"; }
register_proc() {
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$2" "$3" "Thu Sep 25 01:00:00 2026" "$4" "operator" "$5" > "$S/proc/$1"
}
remove_procs() {
  for f in "$S"/proc/*; do
    [ -f "$f" ] || continue
    if [ "$(sed -n 2p "$f")" = "$1" ] && [ "$(sed -n 1p "$f")" = "${YRN_FAKE_UID:-501}" ]; then rm -f "$f"; fi
  done
}
suspend_started() {
  for f in "$S"/vm/*; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f")" = started ]; then echo suspended > "$f"; fi
  done
}
uuid_of() { c=$(printf '%s' "$1" | cksum | cut -d' ' -f1); printf '%08X-0000-4000-8000-%012X' "$c" "$c"; }
'@

$script:MacUtmFakeBody = [ordered]@{
    'utmctl' = @'
DENY='Error from event: The operation could not be completed. (OSStatus error -1743.)'
AETIMEOUT='Error from event: The operation could not be completed. (OSStatus error -1712.)'
OSERR='Error from event: The operation could not be completed. (OSStatus error -2700.)'
cmd="$1"; vm="$2"
case "$cmd" in
  list)
    m=$(mode list); [ -z "$m" ] && m=ok
    case "$m" in
      hang) exec sleep 300 ;;
      deny) echo "$DENY" >&2; exit 0 ;;
      deny-text) echo "Error: Not authorized to send Apple events to UTM." >&2; exit 0 ;;
      timeout-text) echo "$AETIMEOUT" >&2; exit 0 ;;
      ssh) echo "Error: utmctl does not work from SSH sessions or before logging in." >&2; exit 1 ;;
      oserr) echo "$OSERR" >&2; exit 0 ;;
      curly) printf 'Error: The operation couldn\342\200\231t be completed.\n' >&2; exit 0 ;;
      garbage) echo "unexpected banner text"; exit 0 ;;
      empty) exit 0 ;;
      header) echo "UUID                                 Status   Name"; exit 0 ;;
      big) head -c 300000 /dev/zero | tr '\000' 'x'; echo; exit 0 ;;
      *)
        echo "UUID                                 Status   Name"
        for f in "$S"/vm/*; do
          [ -f "$f" ] || continue
          n=$(basename "$f")
          printf '%s %-8s %s\n' "$(uuid_of "$n")" "$(cat "$f")" "$n"
        done
        exit 0 ;;
    esac ;;
  status)
    m=$(mode status); [ -z "$m" ] && m=registry
    case "$m" in
      hang) exec sleep 300 ;;
      oserr-nonzero) echo "$OSERR" >&2; exit 1 ;;
      deny-exit0) echo "$DENY" >&2; exit 0 ;;
      garbage) echo "what"; exit 0 ;;
      notrunning) echo "not running"; exit 0 ;;
      *)
        if [ -f "$S/vm/$vm" ]; then cat "$S/vm/$vm"; exit 0; fi
        echo "Error: Virtual machine not found."; exit 1 ;;
    esac ;;
  start)
    m=$(mode start); [ -z "$m" ] && m=ok
    case "$m" in
      hang) exec sleep 300 ;;
      drop) exit 0 ;;
      deny) echo "$DENY" >&2; exit 0 ;;
      qemu) echo "QEMU error: QEMU exited from an error: Failed to find an available port"; exit 0 ;;
      fail-unknown) echo deny-exit0 > "$S/status.mode"; exit 0 ;;
      fail-exit) echo "Error: start failed" >&2; exit 1 ;;
      *) if [ -f "$S/vm/$vm" ]; then echo started > "$S/vm/$vm"; fi; exit 0 ;;
    esac ;;
  stop)
    m=$(mode stop); [ -z "$m" ] && m=ok
    case "$m" in
      hang) exec sleep 300 ;;
      fail) exit 9 ;;
      deny) echo "$DENY" >&2; exit 0 ;;
      ignore) exit 0 ;;
      *) if [ -f "$S/vm/$vm" ]; then echo stopped > "$S/vm/$vm"; fi; exit 0 ;;
    esac ;;
  delete)
    m=$(mode delete); [ -z "$m" ] && m=ok
    case "$m" in
      hang) exec sleep 300 ;;
      fail) echo "$OSERR"; exit 0 ;;
      *)
        [ -n "$vm" ] || exit 1
        b="$YRN_FAKE_HOME/yuruna/guest.nosync/$vm.utm"
        if [ -d "$b" ]; then rm -rf "$b"; rm -f "$S/vm/$vm"; exit 0; fi
        echo "$OSERR"; exit 0 ;;
    esac ;;
  ip-address)
    ip=$(st "ip.$vm")
    if [ -n "$ip" ]; then echo "$ip"; exit 0; fi
    echo "$OSERR" >&2; exit 0 ;;
esac
exit 0
'@
    'osascript' = @'
if [ "$1" = "-e" ]; then
  case "$2" in
    *"to quit"*)
      m=$(mode quit); [ -z "$m" ] && m=honor
      case "$m" in
        hang) exec sleep 300 ;;
        ignore) exit 0 ;;
        app-only) suspend_started; remove_procs UTM; exit 0 ;;
        *) suspend_started; remove_procs UTM; remove_procs QEMUHelper; exit 0 ;;
      esac ;;
    *) exit 0 ;;
  esac
fi
if [ "$1" = "-l" ]; then echo true; exit 0; fi
m=$(mode watchdog)
if [ "$m" = "live" ]; then
  register_proc "$$" "${YRN_FAKE_UID:-501}" osascript "/usr/bin/osascript $1" real
  echo "$$" >> "$S/spawned"
  exec sleep 120
fi
exit 0
'@
    'pgrep' = @'
m=$(mode pgrep)
case "$m" in
  hang) exec sleep 300 ;;
  fail) echo "pgrep: failure" >&2; exit 3 ;;
  none) exit 1 ;;
esac
U=""; I=""; X=""; F=""; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -U) U="$2"; shift 2 ;;
    -i) I=1; shift ;;
    -x) X=1; shift ;;
    -f) F=1; shift ;;
    *) P="$1"; shift ;;
  esac
done
if [ -z "$U" ]; then echo "fake pgrep: refusing a match not scoped with -U" >&2; exit 2; fi
found=1
for f in "$S"/proc/*; do
  [ -f "$f" ] || continue
  pid=$(basename "$f"); uid=$(sed -n 1p "$f"); name=$(sed -n 2p "$f"); cmd=$(sed -n 4p "$f")
  [ "$uid" = "$U" ] || continue
  # Like pgrep: an extended regex over the name, or over the command line
  # with -f; -x anchors it to the whole string, -i ignores case.
  if [ -n "$F" ]; then s="$cmd"; else s="$name"; fi
  if [ -n "$X" ] && [ -n "$I" ]; then printf '%s\n' "$s" | grep -Eqxi -e "$P" || continue
  elif [ -n "$X" ]; then printf '%s\n' "$s" | grep -Eqx -e "$P" || continue
  elif [ -n "$I" ]; then printf '%s\n' "$s" | grep -Eqi -e "$P" || continue
  else printf '%s\n' "$s" | grep -Eq -e "$P" || continue
  fi
  echo "$pid"; found=0
done
exit $found
'@
    'open' = @'
m=$(mode open); [ -z "$m" ] && m=ok
case "$m" in
  hang) echo "$$" >> "$S/spawned"; exec sleep 120 ;;
  fail) echo "Unable to find application named 'UTM'" >&2; exit 1 ;;
esac
if [ "$1" = "-a" ]; then
  to=$(st pending.rename); from=$(st rename.from)
  if [ -n "$to" ] && [ -n "$from" ] && [ -f "$S/vm/$from" ]; then mv "$S/vm/$from" "$S/vm/$to"; fi
  rm -f "$S/pending.rename"
fi
if [ "$1" = "-a" ] && [ "$m" != "noproc" ]; then
  for f in "$S"/proc/*; do
    [ -f "$f" ] || continue
    if [ "$(sed -n 2p "$f")" = UTM ] && [ "$(sed -n 1p "$f")" = "${YRN_FAKE_UID:-501}" ]; then exit 0; fi
  done
  register_proc "$(next_pid)" "${YRN_FAKE_UID:-501}" UTM "/Applications/UTM.app/Contents/MacOS/UTM" ""
fi
exit 0
'@
    'killall' = @'
if [ "$1" = cfprefsd ]; then exit 0; fi
echo "No matching processes belonging to you were found" >&2
exit 1
'@
    'kill' = @'
m=$(mode kill)
sig=TERM
while [ $# -gt 1 ]; do
  case "$1" in
    -TERM|-15) sig=TERM ;;
    -KILL|-9) sig=KILL ;;
  esac
  shift
done
pid="$1"
if [ "$m" = fail ]; then echo "kill: $pid: Operation not permitted" >&2; exit 1; fi
f="$S/proc/$pid"
if [ ! -f "$f" ]; then echo "kill: $pid: No such process" >&2; exit 1; fi
if [ "$m" = survive ]; then exit 0; fi
if [ "$m" = survive-term ] && [ "$sig" = TERM ]; then exit 0; fi
if [ "$(sed -n 6p "$f")" = real ]; then command kill -s "$sig" "$pid" 2>/dev/null; fi
rm -f "$f"
exit 0
'@
    'ps' = @'
m=$(mode ps)
case "$m" in
  hang) exec sleep 300 ;;
  garble) echo "ps: output this reader cannot parse"; exit 0 ;;
esac
fmt=""; pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) fmt="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
f="$S/proc/$pid"
[ -f "$f" ] || exit 1
uid=$(sed -n 1p "$f"); start=$(sed -n 3p "$f"); cmd=$(sed -n 4p "$f"); user=$(sed -n 5p "$f")
alt=$(pop "ps.start.$pid.queue"); if [ -n "$alt" ]; then start="$alt"; fi
case "$fmt" in
  'uid=,lstart=,command=') printf '%5s %s %s\n' "$uid" "$start" "$cmd" ;;
  'user=') printf '%s\n' "$user" ;;
  'pid=') printf '%5s\n' "$pid" ;;
  *) printf '%s\n' "$cmd" ;;
esac
exit 0
'@
    'id' = @'
m=$(mode id)
case "$m" in
  hang) exec sleep 300 ;;
  fail) exit 1 ;;
esac
if [ "$1" = "-u" ]; then echo "${YRN_FAKE_UID:-501}"; fi
exit 0
'@
    'PlistBuddy' = @'
m=$(mode plistbuddy)
case "$m" in hang) exec sleep 300 ;; esac
c=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) c="$2"; shift 2 ;;
    *) shift ;;
  esac
done
fail=$(st plistbuddy.fail)
if [ -n "$fail" ]; then
  case "$c" in *"$fail"*) echo "Set: Entry, \"$c\", Does Not Exist" >&2; exit 1 ;; esac
fi
case "$c" in
  "Set :Registry:"*":Name "*) echo "${c##* }" > "$S/pending.rename" ;;
esac
if [ "$c" = "Print :Information:UUID" ]; then
  u=$(st bundle.uuid); [ -z "$u" ] && u=6B9A5B8F-0000-4000-8000-000000000001
  echo "$u"
fi
exit 0
'@
    'plutil' = @'
m=$(mode plutil)
case "$m" in hang) exec sleep 300 ;; esac
file=""
for a in "$@"; do file="$a"; done
if [ -f "$file.json" ]; then cat "$file.json"; exit 0; fi
echo "$file: file does not exist or is not a plist" >&2
exit 1
'@
    'qemu-img' = @'
if [ "$1" = info ]; then
  if [ -f "$S/qemuimg.locked" ]; then echo 'qemu-img: Failed to get shared "write" lock' >&2; exit 1; fi
  echo "image: $2"
fi
exit 0
'@
    'arp' = @'
m=$(mode arp)
case "$m" in
  hang) exec sleep 300 ;;
  fail) echo "arp: sysctl failure" >&2; exit 1 ;;
esac
if [ -f "$S/arp.txt" ]; then cat "$S/arp.txt"; fi
exit 0
'@
    'launchctl' = @'
m=$(mode launchctl)
case "$m" in hang) exec sleep 300 ;; esac
if [ "$1" = managername ]; then echo "${YRN_FAKE_MANAGER:-Aqua}"; fi
exit 0
'@
    'ifconfig' = @'
m=$(mode ifconfig)
case "$m" in hang) exec sleep 300 ;; esac
if [ -f "$S/ifconfig.txt" ]; then cat "$S/ifconfig.txt"; fi
exit 0
'@
    'sudo' = @'
m=$(mode sudo); [ -z "$m" ] && m=ok
case "$m" in
  hang) exec sleep 300 ;;
  deny) echo "sudo: a password is required" >&2; exit 1 ;;
esac
exit 0
'@
}

# Driver tool-table key -> stand-in file name.
$script:MacUtmFakeToolFile = @{
    'arp' = 'arp'; 'dscl' = 'dscl'; 'id' = 'id'; 'ifconfig' = 'ifconfig'; 'kill' = 'kill'; 'killall' = 'killall'
    'launchctl' = 'launchctl'; 'open' = 'open'; 'osascript' = 'osascript'; 'pgrep' = 'pgrep'
    'plistbuddy' = 'PlistBuddy'; 'plutil' = 'plutil'; 'ps' = 'ps'; 'qemu-img' = 'qemu-img'; 'sudo' = 'sudo'
}

function New-MacUtmFakeHost {
    <#
    .SYNOPSIS
        Build a fake macOS/UTM host under -Root: stand-in tools, state, a
        private home, and the UTM preference plist Rename-VM edits.
    .PARAMETER Root
        Private directory; created, and owned by the caller's test.
    .PARAMETER Uid
        The uid the stand-ins report for this user.
    .OUTPUTS
        [pscustomobject] Root, Bin, UtmBin, State, Proc, Log, Home, Uid.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes only into the caller-owned private root.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Uid = '501'
    )
    $fake = [pscustomobject]@{
        Root   = $Root
        Bin    = Join-Path $Root 'bin'
        SupportBin = Join-Path $Root 'supportbin'
        UtmBin = Join-Path $Root 'utmbin'
        State  = Join-Path $Root 'state'
        Proc   = Join-Path $Root 'state/proc'
        Log    = Join-Path $Root 'calls.log'
        Home   = Join-Path $Root 'home'
        Uid    = $Uid
        Created = [DateTime]::Now.AddSeconds(-1)
        Saved  = @{}
    }
    foreach ($dir in @($fake.Bin, $fake.SupportBin, $fake.UtmBin, $fake.State, $fake.Proc, (Join-Path $fake.State 'vm'),
            (Join-Path $fake.Home 'yuruna/guest.nosync'), (Join-Path $fake.Home 'yuruna/image'),
            (Join-Path $fake.Home 'Library/Containers/com.utmapp.UTM/Data/Library/Preferences'))) {
        $null = New-Item -ItemType Directory -Force -Path $dir
    }
    [System.IO.File]::WriteAllText((Join-Path $fake.Home 'Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist'), "<plist/>`n")
    [System.IO.File]::WriteAllText($fake.Log, '')
    # Keep the stand-ins' shell utilities available without inheriting a real
    # utmctl (or another host control tool) from the caller's PATH. In
    # particular, the missing-client and bundle-only cases must stay isolated
    # on a Mac that actually has UTM installed.
    foreach ($name in @('basename', 'cat', 'chmod', 'cksum', 'cut', 'grep', 'head', 'mv', 'rm', 'sed', 'sleep', 'tail', 'tr')) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $fake.SupportBin $name) -Target $command.Source
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    foreach ($tool in $script:MacUtmFakeBody.Keys) {
        $dir = if ($tool -eq 'utmctl') { $fake.UtmBin } else { $fake.Bin }
        $path = Join-Path $dir $tool
        # LF only: /bin/sh rejects a CR in the shebang line.
        $text = ($script:MacUtmFakePrologue -replace "`r", '') + "`n" + ($script:MacUtmFakeBody[$tool] -replace "`r", '') + "`n"
        $text = $text.Replace('#!/bin/sh', "#!/bin/sh`nYRN_TOOL='$tool'")
        [System.IO.File]::WriteAllText($path, $text, $utf8)
        & chmod +x $path
    }
    return $fake
}

function Enter-MacUtmFakeHost {
    <#
    .SYNOPSIS
        Point PATH, $HOME and the loaded macOS driver at a fake host.
    .PARAMETER FakeHost
        New-MacUtmFakeHost output.
    .PARAMETER SessionKind
        What the driver's GUI-session probe answers.
    .PARAMETER Utmctl
        'path' puts the fake utmctl on PATH; 'bundle' leaves it off PATH and
        makes it the driver's in-bundle copy; 'missing' provides neither.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][pscustomobject]$FakeHost,
        [ValidateSet('Aqua', 'Remote', 'Unknown')][string]$SessionKind = 'Aqua',
        [ValidateSet('path', 'bundle', 'missing')][string]$Utmctl = 'path'
    )
    $saved = $FakeHost.Saved
    $saved['PATH'] = $env:PATH
    $saved['HOME'] = $HOME
    foreach ($name in 'YRN_FAKE_STATE', 'YRN_FAKE_LOG', 'YRN_FAKE_UID', 'YRN_FAKE_MANAGER', 'YRN_FAKE_HOME') {
        $saved["env:$name"] = [Environment]::GetEnvironmentVariable($name)
    }
    $separator = [System.IO.Path]::PathSeparator
    $privatePath = "$($FakeHost.Bin)$separator$($FakeHost.SupportBin)"
    $env:PATH = if ($Utmctl -eq 'path') { "$($FakeHost.UtmBin)$separator$privatePath" } else { $privatePath }
    $env:YRN_FAKE_STATE = $FakeHost.State
    $env:YRN_FAKE_LOG   = $FakeHost.Log
    $env:YRN_FAKE_UID   = $FakeHost.Uid
    $env:YRN_FAKE_HOME  = $FakeHost.Home
    Set-Variable -Name HOME -Value $FakeHost.Home -Scope Global -Force

    $driver = Get-MacUtmFakeDriver
    if ($driver) {
        $toolPath = @{}
        foreach ($key in $script:MacUtmFakeToolFile.Keys) { $toolPath[$key] = Join-Path $FakeHost.Bin $script:MacUtmFakeToolFile[$key] }
        $bundlePath = switch ($Utmctl) {
            'bundle' { Join-Path $FakeHost.UtmBin 'utmctl' }
            default  { Join-Path $FakeHost.Root 'no-such-bundle/utmctl' }
        }
        $saved['driver'] = & $driver {
            param($ToolPath, $BundlePath, $FakeHome, $Interpreter, $LeasePath, $Kind)
            $prior = @{
                UtmHostTool = $script:UtmHostTool.Clone(); UtmctlBundlePath = $script:UtmctlBundlePath
                WatchdogPidFile = $script:WatchdogPidFile; WatchdogScriptPath = $script:WatchdogScriptPath
                WatchdogLogPath = $script:WatchdogLogPath; WatchdogIdentityPath = $script:WatchdogIdentityPath
                WatchdogInterpreterPath = $script:WatchdogInterpreterPath
                UtmStatePollMilliseconds = $script:UtmStatePollMilliseconds
                UtmStartSettlePollMilliseconds = $script:UtmStartSettlePollMilliseconds
                UtmDeleteRetryDelaySeconds = $script:UtmDeleteRetryDelaySeconds
                UtmHardStopWaitMilliseconds = $script:UtmHardStopWaitMilliseconds
                UtmPreferenceFlushSettleMilliseconds = $script:UtmPreferenceFlushSettleMilliseconds
                UtmSharedLeasePath = $script:UtmSharedLeasePath
                UtmRenameQuitWaitSeconds = $script:UtmRenameQuitWaitSeconds
                UtmRenameLaunchWaitSeconds = $script:UtmRenameLaunchWaitSeconds
                UtmRenameSurfaceWaitMilliseconds = $script:UtmRenameSurfaceWaitMilliseconds
                SessionFunction = ${function:Get-UtmProbeSessionKind}
            }
            foreach ($key in $ToolPath.Keys) { $script:UtmHostTool[$key] = $ToolPath[$key] }
            $script:UtmctlBundlePath = $BundlePath
            $script:WatchdogPidFile = Join-Path $FakeHome 'yuruna/image/utm-dialog-watchdog.pid'
            $script:WatchdogScriptPath = Join-Path $FakeHome 'yuruna/image/utm-dialog-watchdog.applescript'
            $script:WatchdogLogPath = Join-Path $FakeHome 'yuruna/image/utm-dialog-watchdog.log'
            $script:WatchdogIdentityPath = Join-Path $FakeHome 'yuruna/image/utm-dialog-watchdog.identity.json'
            $script:WatchdogInterpreterPath = $Interpreter
            $script:UtmStatePollMilliseconds = 50
            $script:UtmStartSettlePollMilliseconds = 50
            $script:UtmDeleteRetryDelaySeconds = 0
            $script:UtmHardStopWaitMilliseconds = 400
            $script:UtmPreferenceFlushSettleMilliseconds = 0
            $script:UtmSharedLeasePath = $LeasePath
            $script:UtmRenameQuitWaitSeconds = 2
            $script:UtmRenameLaunchWaitSeconds = 2
            $script:UtmRenameSurfaceWaitMilliseconds = 3000
            $script:UtmCurrentUid = $null
            $script:MacUtmFakeSessionKind = $Kind
            Set-Item -Path 'function:script:Get-UtmProbeSessionKind' -Value { param($Deadline) $null = $Deadline; return $script:MacUtmFakeSessionKind }
            return $prior
        } $toolPath $bundlePath $FakeHost.Home (Join-Path $FakeHost.Bin 'osascript') (Join-Path $FakeHost.State 'dhcpd_leases') $SessionKind
    }
}

function Exit-MacUtmFakeHost {
    <#
    .SYNOPSIS
        Undo Enter-MacUtmFakeHost: PATH, $HOME, environment and driver state.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$FakeHost)
    $saved = $FakeHost.Saved
    if ($saved.ContainsKey('PATH')) { $env:PATH = $saved['PATH'] }
    if ($saved.ContainsKey('HOME')) { Set-Variable -Name HOME -Value $saved['HOME'] -Scope Global -Force }
    foreach ($name in 'YRN_FAKE_STATE', 'YRN_FAKE_LOG', 'YRN_FAKE_UID', 'YRN_FAKE_MANAGER', 'YRN_FAKE_HOME') {
        $value = $saved["env:$name"]
        if ($null -eq $value) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $value) }
    }
    $driver = Get-MacUtmFakeDriver
    if ($driver -and $saved['driver']) {
        & $driver {
            param($Prior)
            $script:UtmHostTool = $Prior.UtmHostTool
            $script:UtmctlBundlePath = $Prior.UtmctlBundlePath
            $script:WatchdogPidFile = $Prior.WatchdogPidFile
            $script:WatchdogScriptPath = $Prior.WatchdogScriptPath
            $script:WatchdogLogPath = $Prior.WatchdogLogPath
            $script:WatchdogIdentityPath = $Prior.WatchdogIdentityPath
            $script:WatchdogInterpreterPath = $Prior.WatchdogInterpreterPath
            $script:UtmStatePollMilliseconds = $Prior.UtmStatePollMilliseconds
            $script:UtmStartSettlePollMilliseconds = $Prior.UtmStartSettlePollMilliseconds
            $script:UtmDeleteRetryDelaySeconds = $Prior.UtmDeleteRetryDelaySeconds
            $script:UtmHardStopWaitMilliseconds = $Prior.UtmHardStopWaitMilliseconds
            $script:UtmPreferenceFlushSettleMilliseconds = $Prior.UtmPreferenceFlushSettleMilliseconds
            $script:UtmSharedLeasePath = $Prior.UtmSharedLeasePath
            $script:UtmRenameQuitWaitSeconds = $Prior.UtmRenameQuitWaitSeconds
            $script:UtmRenameLaunchWaitSeconds = $Prior.UtmRenameLaunchWaitSeconds
            $script:UtmRenameSurfaceWaitMilliseconds = $Prior.UtmRenameSurfaceWaitMilliseconds
            $script:UtmCurrentUid = $null
            Set-Item -Path 'function:script:Get-UtmProbeSessionKind' -Value $Prior.SessionFunction
        } $saved['driver']
        $saved.Remove('driver')
    }
}

function Get-MacUtmFakeDriver {
    <#
    .SYNOPSIS
        The loaded macOS driver module, or $null.
    #>
    [CmdletBinding()]
    [OutputType([psmoduleinfo])]
    param()
    return (Get-Module -Name 'Yuruna.Host' -All | Where-Object { "$($_.Path)" -match '[\\/]macos\.utm[\\/]' } | Select-Object -First 1)
}

function Set-MacUtmFakeState {
    <#
    .SYNOPSIS
        Write (or remove) one state file the stand-ins read.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes only into the fake host state directory.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][pscustomobject]$FakeHost,
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Value = '',
        [switch]$Remove
    )
    $path = Join-Path $FakeHost.State $Key
    if ($Remove) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; return }
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
    [System.IO.File]::WriteAllText($path, (($Value -replace "`r", '') + "`n"))
}

function Add-MacUtmFakeProcess {
    <#
    .SYNOPSIS
        Add one row to the fake process table.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes only into the fake host state directory.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][pscustomobject]$FakeHost,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$Name,
        [string]$Uid,
        [string]$StartText = 'Thu Sep 25 01:00:00 2026',
        [string]$Command,
        [string]$User = 'operator'
    )
    if (-not $Uid) { $Uid = $FakeHost.Uid }
    if (-not $Command) { $Command = if ($Name -eq 'UTM') { '/Applications/UTM.app/Contents/MacOS/UTM' } else { "/Applications/UTM.app/Contents/XPCServices/$Name.xpc/Contents/MacOS/$Name" } }
    $row = @($Uid, $Name, $StartText, $Command, $User, '') -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $FakeHost.Proc "$ProcessId"), "$row`n")
}

function Add-MacUtmFakeVM {
    <#
    .SYNOPSIS
        Register a VM with the fake utmctl and, optionally, create its bundle
        with a config.plist and the JSON the fake plutil prints for it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes only into the fake host directories.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][pscustomobject]$FakeHost,
        [Parameter(Mandatory)][string]$Name,
        [string]$Status = 'stopped',
        [switch]$Unregistered,
        [switch]$WithBundle,
        [string]$MacAddress = '52:54:00:AA:BB:CC',
        [ValidateSet('Shared', 'Bridged', '')][string]$Mode = 'Shared',
        [int]$Display = 47,
        [ValidateRange(0, 8)][int]$DiskCount = 0,
        [string]$VmState
    )
    if (-not $Unregistered) { Set-MacUtmFakeState -FakeHost $FakeHost -Key "vm/$Name" -Value $Status }
    if ($WithBundle) {
        $bundle = Join-Path $FakeHost.Home "yuruna/guest.nosync/$Name.utm"
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'Data')
        $plist = Join-Path $bundle 'config.plist'
        [System.IO.File]::WriteAllText($plist, "<plist/>`n")
        $json = [ordered]@{
            Information = [ordered]@{ Name = $Name; UUID = '6B9A5B8F-0000-4000-8000-000000000001' }
            Network     = @([ordered]@{ Mode = $Mode; MacAddress = $MacAddress })
            QEMU        = [ordered]@{ AdditionalArguments = @('-vnc', "127.0.0.1:$Display,share=force-shared") }
        }
        [System.IO.File]::WriteAllText("$plist.json", ($json | ConvertTo-Json -Depth 5))
        for ($i = 0; $i -lt $DiskCount; $i++) { [System.IO.File]::WriteAllText((Join-Path $bundle "Data/disk$i.qcow2"), "qcow2 $i") }
        if ($PSBoundParameters.ContainsKey('VmState')) { [System.IO.File]::WriteAllText((Join-Path $bundle 'Data/vmstate'), $VmState) }
    }
}

function Reset-MacUtmFakeHost {
    <#
    .SYNOPSIS
        Return a fake host to its initial state: no VMs, no processes, no
        modes, no bundles, an empty call log.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: rewrites only the fake host directories.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$FakeHost)
    foreach ($item in @(Get-ChildItem -LiteralPath $FakeHost.State -Force -ErrorAction SilentlyContinue)) {
        if ($item.Name -in @('vm', 'proc', 'spawned')) { continue }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($dir in @((Join-Path $FakeHost.State 'vm'), $FakeHost.Proc, (Join-Path $FakeHost.Home 'yuruna/guest.nosync'), (Join-Path $FakeHost.Home 'yuruna/image'))) {
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Clear-MacUtmFakeCall -FakeHost $FakeHost
    Set-MacUtmFakeUid -FakeHost $FakeHost -Uid $FakeHost.Uid
}

function Set-MacUtmFakeUid {
    <#
    .SYNOPSIS
        Change the uid the stand-ins report, and drop the driver's cached uid.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: changes only the fake host environment and the driver cache.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][pscustomobject]$FakeHost,
        [Parameter(Mandatory)][string]$Uid
    )
    Write-Verbose "fake host $($FakeHost.Root): stand-ins now report uid $Uid"
    $env:YRN_FAKE_UID = $Uid
    $driver = Get-MacUtmFakeDriver
    if ($driver) { & $driver { $script:UtmCurrentUid = $null } }
}

function Get-MacUtmFakeCall {
    <#
    .SYNOPSIS
        The logged stand-in calls, optionally only those of one tool.
    .OUTPUTS
        [string[]] one line per call: the tool name, then its arguments.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$FakeHost,
        [string]$Tool
    )
    $lines = @([System.IO.File]::ReadAllLines($FakeHost.Log) | Where-Object { $_ })
    if ($Tool) { $lines = @($lines | Where-Object { $_ -eq $Tool -or $_.StartsWith("$Tool ") }) }
    return [string[]]$lines
}

function Clear-MacUtmFakeCall {
    <#
    .SYNOPSIS
        Empty the call log.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$FakeHost)
    [System.IO.File]::WriteAllText($FakeHost.Log, '')
}

function Remove-MacUtmFakeHost {
    <#
    .SYNOPSIS
        Stop the processes the stand-ins themselves started, then delete the
        fake host directory.
    .DESCRIPTION
        Only pids a stand-in recorded for its own live process are signaled:
        the long-running launcher and watchdog stand-ins. Nothing else on the
        host is touched.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: removes only the fake host and its own stand-in processes.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$FakeHost)
    $spawned = Join-Path $FakeHost.State 'spawned'
    if (Test-Path -LiteralPath $spawned) {
        foreach ($line in [System.IO.File]::ReadAllLines($spawned)) {
            $value = 0
            if (-not [int]::TryParse($line.Trim(), [ref]$value) -or $value -le 0) { continue }
            $proc = Get-Process -Id $value -ErrorAction SilentlyContinue
            # Only the stand-in itself: the pid still runs the sleep the
            # stand-in replaced itself with, started after this fake host was
            # built, so a reused pid is never signaled.
            if ($proc -and "$($proc.Path)$($proc.CommandLine)" -match 'sleep' -and $proc.StartTime -ge $FakeHost.Created) {
                Stop-Process -Id $value -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Remove-Item -LiteralPath $FakeHost.Root -Recurse -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function New-MacUtmFakeHost, Enter-MacUtmFakeHost, Exit-MacUtmFakeHost, Get-MacUtmFakeDriver,
    Set-MacUtmFakeState, Add-MacUtmFakeProcess, Add-MacUtmFakeVM, Get-MacUtmFakeCall, Clear-MacUtmFakeCall, Remove-MacUtmFakeHost,
    Reset-MacUtmFakeHost, Set-MacUtmFakeUid
