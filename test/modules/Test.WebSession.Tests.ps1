<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42c5129b-d650-4268-a832-4e07ddc36a65
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test web session tunnel devtools pester
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
    Prove the web session of a guest: the SSH tunnel to its browser, the
    session table and its lifetime, the DevTools client, the locator, the page
    operations, the page verbs and the account a failed page step files.
.DESCRIPTION
    A page step drives a browser that runs in the guest, reached through an SSH
    tunnel. A session that outlives its sequence, a tunnel that keeps a dead
    browser, a click that is sent twice or a failure filed under the wrong class
    are the defects this suite exists for. No case needs a VM or a browser: the
    tunnel runs a stand-in ssh, and the protocol client runs over a scripted
    transport whose clock the case drives (the client never sleeps), so every
    case of the client blocks runs in milliseconds.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceEngine.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Ssh.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Force -Global -DisableNameChecking
    $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'PATH', 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime'
    $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'log'
    $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR, $env:YURUNA_LOG_DIR -Force

    # Seams of the protocol client blocks. The client waits only inside
    # its transport read and compares DateTime deadlines with the connection's
    # Clock, so a scripted transport that moves that clock drives every wait.

    function New-WebTestClock {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test clock.')]
        param([datetime]$Now = [DateTime]::new(2030, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
        return @{ Now = $Now }
    }

    function New-WebTestTransport {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The closures of the transport use the parameters.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory scripted transport.')]
        param(
            [Parameter(Mandatory)][scriptblock]$Responder,
            [Parameter(Mandatory)][hashtable]$Clock
        )
        $state = @{
            Sent    = [System.Collections.Generic.List[object]]::new()
            Inbound = [System.Collections.Generic.List[object]]::new()
            Closed  = $false
            Order   = 0L
            Count   = @{}
        }
        $jsonOption = @{}
        if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOption.DateKind = 'String' }
        $enqueue = {
            param($Message, [int]$AfterMs = 0)
            $copy = [ordered]@{}
            $delay = $AfterMs
            foreach ($key in @($Message.Keys)) {
                if ($key -ceq '_afterMs') { $delay = [int]$Message[$key]; continue }
                $copy[$key] = $Message[$key]
            }
            $state.Order++
            $item = @{ Due = ([datetime]$Clock.Now).AddMilliseconds($delay); Order = $state.Order; Text = (ConvertTo-Json -InputObject $copy -Depth 32 -Compress) }
            # Kept in (Due, Order) order, so a receive takes the head: a case
            # that queues hundreds of messages stays fast.
            $at = $state.Inbound.Count
            while ($at -gt 0 -and $state.Inbound[$at - 1].Due -gt $item.Due) { $at-- }
            $state.Inbound.Insert($at, $item)
        }.GetNewClosure()
        $send = {
            param([string]$Text)
            if ($state.Closed) { throw (New-WebFailureException -Kind 'transport' -Detail 'socket closed') }
            $message = ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 512 @jsonOption
            $state.Sent.Add($message)
            $answers = & $Responder $message $state
            foreach ($answer in @($answers)) {
                if ($answer -is [string] -and $answer -ceq 'close') {
                    $state.Closed = $true
                    throw (New-WebFailureException -Kind 'transport' -Detail 'socket closed')
                }
                if ($answer -is [System.Collections.IDictionary]) { & $enqueue $answer 0 }
            }
        }.GetNewClosure()
        $receive = {
            param([int]$TimeoutMs)
            if ($state.Closed) { throw (New-WebFailureException -Kind 'transport' -Detail 'socket closed') }
            $now = [datetime]$Clock.Now
            $limit = $now.AddMilliseconds($TimeoutMs)
            if ($state.Inbound.Count -eq 0 -or $state.Inbound[0].Due -gt $limit) {
                $Clock.Now = $limit
                return $null
            }
            $best = $state.Inbound[0]
            $state.Inbound.RemoveAt(0)
            if ($best.Due -gt $now) { $Clock.Now = $best.Due }
            return $best.Text
        }.GetNewClosure()
        $close = { $state.Closed = $true }.GetNewClosure()
        return @{ Kind = 'scripted'; Send = $send; Receive = $receive; Close = $close; Enqueue = $enqueue; State = $state; Clock = $Clock; Closed = $false }
    }

    function Add-WebTestEvent {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '',
            Justification = 'The parameter name -Event is the seam interface; the function never assigns it.')]
        param(
            [Parameter(Mandatory)][hashtable]$Transport,
            [Parameter(Mandatory)][System.Collections.IDictionary]$Event,
            [int]$AfterMs = 0
        )
        & $Transport.Enqueue $Event $AfterMs
    }

    # A reply or an error to one sent message, for responders and overrides.
    function New-WebTestReply {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory reply message.')]
        param(
            [Parameter(Mandatory)][System.Collections.IDictionary]$Message,
            [System.Collections.IDictionary]$Result = @{},
            [int]$AfterMs = 0
        )
        $reply = [ordered]@{ id = $Message['id']; result = $Result }
        if ($Message.Contains('sessionId')) { $reply['sessionId'] = $Message['sessionId'] }
        if ($AfterMs -gt 0) { $reply['_afterMs'] = $AfterMs }
        return $reply
    }

    function New-WebTestError {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory error message.')]
        param(
            [Parameter(Mandatory)][System.Collections.IDictionary]$Message,
            [Parameter(Mandatory)][int]$Code,
            [string]$Text = 'fixture error',
            [int]$AfterMs = 0
        )
        $reply = [ordered]@{ id = $Message['id']; error = [ordered]@{ code = $Code; message = $Text } }
        if ($Message.Contains('sessionId')) { $reply['sessionId'] = $Message['sessionId'] }
        if ($AfterMs -gt 0) { $reply['_afterMs'] = $AfterMs }
        return $reply
    }

    function New-WebTestAxNode {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory accessibility node.')]
        param(
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Role,
            [AllowNull()][AllowEmptyString()][string]$Name,
            [AllowEmptyCollection()][string[]]$Children = @(),
            [int]$Backend = 0,
            [System.Collections.IDictionary]$Props,
            [AllowNull()]$Value,
            [switch]$Ignored
        )
        $node = [ordered]@{ nodeId = $Id; ignored = [bool]$Ignored; role = [ordered]@{ type = 'role'; value = $Role } }
        if ($PSBoundParameters.ContainsKey('Name')) { $node['name'] = [ordered]@{ type = 'computedString'; value = [string]$Name } }
        if ($null -ne $Value) { $node['value'] = [ordered]@{ type = 'string'; value = $Value } }
        if ($Props) {
            $node['properties'] = @(foreach ($propName in $Props.Keys) { [ordered]@{ name = [string]$propName; value = [ordered]@{ type = 'value'; value = $Props[$propName] } } })
        }
        $node['childIds'] = @($Children)
        if ($Backend -gt 0) { $node['backendDOMNodeId'] = $Backend }
        return $node
    }

    # A responder that answers from tables. Ax maps '<session>' or
    # '<session>|<frameId>' to an array of nodes (or a scriptblock
    # param($Message, $State, $Read) that returns one, $Read counting the reads
    # of that key from 1); a missing frame answers -32602. Quads and Box map a
    # backend node id to a content quad (or a list of quads) and to a content
    # box; Hit maps a session to the backend id its hit test answers (default:
    # the node of the last geometry read on that session); Describe maps a
    # backend id, or 'node:<nodeId>', to the node describeNode returns; Partial
    # maps a backend id to the node getPartialAXTree returns (default: the
    # node of the Ax tables with that backend id); Metrics maps a session to its
    # cssLayoutViewport. Override maps a method to a scriptblock
    # param($Message, $State) that returns the messages to queue (nothing
    # withholds the reply). The seven setup commands of the owned page answer
    # target T1, session S1 and main frame T1.
    function New-WebTestPage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The closure of the responder uses the tables.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory responder.')]
        param(
            [hashtable]$Ax = @{},
            [hashtable]$Quads = @{},
            [hashtable]$Box = @{},
            [hashtable]$Hit = @{},
            [hashtable]$Describe = @{},
            [hashtable]$Partial = @{},
            [hashtable]$Metrics = @{},
            [hashtable]$Override = @{}
        )
        # A closure does not see the functions of this scope: carry them in.
        $newReply = ${function:New-WebTestReply}
        $newError = ${function:New-WebTestError}
        $reads = @{}
        $lastGeometry = @{}
        $resolveAx = {
            param($Key, $Message, $State)
            $value = $Ax[$Key]
            if ($value -is [scriptblock]) {
                $reads[$Key] = 1 + [int]$reads[$Key]
                $value = & $value $Message $State $reads[$Key]
            }
            $nodes = @($value | Where-Object { $null -ne $_ })
            $parents = @{}
            foreach ($node in $nodes) { foreach ($childId in @($node['childIds'])) { $parents[[string]$childId] = [string]$node['nodeId'] } }
            foreach ($node in $nodes) {
                if (-not $node.Contains('parentId') -and $parents.ContainsKey([string]$node['nodeId'])) { $node['parentId'] = $parents[[string]$node['nodeId']] }
            }
            return , $nodes
        }.GetNewClosure()
        return {
            param($Message, $State)
            $method = [string]$Message['method']
            $params = if ($Message['params'] -is [System.Collections.IDictionary]) { $Message['params'] } else { @{} }
            $session = [string]$Message['sessionId']
            $State.Count[$method] = 1 + [int]$State.Count[$method]
            if ($Override.ContainsKey($method)) { return (& $Override[$method] $Message $State) }
            $reply = { param([System.Collections.IDictionary]$Result) & $newReply -Message $Message -Result $Result }
            switch -CaseSensitive ($method) {
                'Target.createTarget' { return (& $reply @{ targetId = 'T1' }) }
                'Target.attachToTarget' { return (& $reply @{ sessionId = 'S1' }) }
                'Page.getFrameTree' { return (& $reply @{ frameTree = @{ frame = @{ id = 'T1' } } }) }
                'Target.closeTarget' { return (& $reply @{ success = $true }) }
                'DOM.getDocument' { return (& $reply @{ root = @{ nodeId = 1 } }) }
                'Accessibility.getFullAXTree' {
                    $key = if ($params.Contains('frameId')) { "$session|$($params['frameId'])" } else { $session }
                    if (-not $Ax.ContainsKey($key)) {
                        if ($params.Contains('frameId')) { return (& $newError -Message $Message -Code -32602 -Text 'Frame with the given frameId is not found.') }
                        return (& $reply @{ nodes = @() })
                    }
                    return (& $reply @{ nodes = (& $resolveAx $key $Message $State) })
                }
                'Accessibility.getPartialAXTree' {
                    $backend = [int]$params['backendNodeId']
                    if ($Partial.ContainsKey($backend)) {
                        $value = $Partial[$backend]
                        if ($value -is [scriptblock]) { $value = & $value $Message $State }
                        if ($null -eq $value) { return (& $newError -Message $Message -Code -32000 -Text 'No node with given id found') }
                        return (& $reply @{ nodes = @($value) })
                    }
                    foreach ($key in @($Ax.Keys)) {
                        if ($Ax[$key] -is [scriptblock]) { continue }
                        foreach ($node in @($Ax[$key])) {
                            if ($null -ne $node -and [int]$node['backendDOMNodeId'] -eq $backend) { return (& $reply @{ nodes = @($node) }) }
                        }
                    }
                    return (& $newError -Message $Message -Code -32000 -Text 'No node with given id found')
                }
                'DOM.getContentQuads' {
                    $backend = [int]$params['backendNodeId']
                    $lastGeometry[$session] = $backend
                    $value = $Quads[$backend]
                    if ($value -is [scriptblock]) { $value = & $value $Message $State }
                    if ($null -eq $value) { return (& $reply @{ quads = @() }) }
                    $list = @($value)
                    # A list, not an if expression: the pipeline would unroll a
                    # one-quad wrapper into a flat list of numbers.
                    $quadList = [System.Collections.Generic.List[object]]::new()
                    if ($list.Count -gt 0 -and ($list[0] -is [array] -or $list[0] -is [System.Collections.IList])) {
                        foreach ($quad in $list) { $quadList.Add([object[]]@($quad)) }
                    } else {
                        $quadList.Add([object[]]$list)
                    }
                    return (& $reply @{ quads = $quadList.ToArray() })
                }
                'DOM.getBoxModel' {
                    $backend = [int]$params['backendNodeId']
                    $lastGeometry[$session] = $backend
                    $content = $Box[$backend]
                    if ($null -eq $content) { $content = @(0, 0, 10, 0, 10, 10, 0, 10) }
                    return (& $reply @{ model = @{ content = @($content) } })
                }
                'DOM.getNodeForLocation' {
                    $value = if ($Hit.ContainsKey($session)) { $Hit[$session] } else { $lastGeometry[$session] }
                    if ($value -is [scriptblock]) { $value = & $value $Message $State }
                    if ($null -eq $value) { return (& $newError -Message $Message -Code -32000 -Text 'No node found at given location') }
                    return (& $reply @{ backendNodeId = [int]$value })
                }
                'DOM.describeNode' {
                    $key = if ($params.Contains('nodeId')) { "node:$($params['nodeId'])" } else { [int]$params['backendNodeId'] }
                    $value = $Describe[$key]
                    if ($value -is [scriptblock]) { $value = & $value $Message $State }
                    if ($null -eq $value) { $value = @{ backendNodeId = [int]$params['backendNodeId']; nodeName = 'DIV'; attributes = @() } }
                    return (& $reply @{ node = $value })
                }
                'Page.getLayoutMetrics' {
                    $viewport = $Metrics[$session]
                    if ($null -eq $viewport) { $viewport = @{ clientWidth = 1280; clientHeight = 800; pageX = 0; pageY = 0 } }
                    return (& $reply @{ cssLayoutViewport = $viewport })
                }
                'Page.navigate' { return (& $reply @{ frameId = 'T1'; loaderId = 'L1' }) }
                default { return (& $reply @{}) }
            }
        }.GetNewClosure()
    }

    function New-WebTestConnection {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory connection over a scripted transport.')]
        param(
            [Parameter(Mandatory)][scriptblock]$Responder,
            [hashtable]$Clock
        )
        if (-not $Clock) { $Clock = New-WebTestClock }
        $transport = New-WebTestTransport -Responder $Responder -Clock $Clock
        $connection = InModuleScope Test.WebSession -Parameters @{ Transport = $transport; Clock = $Clock } {
            param($Transport, $Clock)
            New-WebCdpConnection -Transport $Transport -Clock $Clock
        }
        Open-WebCdpPage -Connection $connection -DeadlineUtc ([datetime]$Clock.Now).AddSeconds(30)
        $transport.State.Sent.Clear()
        return @{ Connection = $connection; Transport = $transport; Clock = $Clock }
    }

    function New-WebTestSession {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory web session entry.')]
        param(
            [Parameter(Mandatory)][AllowNull()][hashtable]$Connection,
            [string]$VMName = 'fixture-vm'
        )
        return @{
            VMName      = $VMName
            GuestKey    = 'guest.ubuntu.server.26'
            Generation  = 1
            OwnerId     = 'seq'
            State       = 'open'
            OpenedUtc   = [datetime]::UtcNow
            ClosedUtc   = $null
            CloseReason = ''
            LocalPort   = 1
            Tunnel      = $null
            Product     = 'Fake/1.0'
            Cdp         = $Connection
        }
    }

    function New-WebTestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory handler context and resets the step slots as the engine does.')]
        param(
            [Parameter(Mandatory)][System.Collections.IDictionary]$Step,
            [string]$VMName = 'fixture-vm',
            [scriptblock]$ExpandVariable = { param($Value) $Value }
        )
        $stepId = [guid]::NewGuid().ToString('N')
        Reset-SequenceFailureSlot -Lifetime step
        (Get-SequenceFailureState).LastFailedStepInvocationId = $stepId
        return @{
            Step                  = $Step
            Vars                  = @{}
            VMName                = $VMName
            GuestKey              = 'guest.ubuntu.server.26'
            SequenceInvocationId  = 'seq'
            StepInvocationId      = $stepId
            DefaultTimeoutSeconds = 5
            ShowSensitive         = $false
            ExpandVariable        = $ExpandVariable
        }
    }

    # A private function of the module, called inside its scope.
    function Invoke-WebTestPrivate {
        param(
            [Parameter(Mandatory)][string]$Name,
            [hashtable]$Arguments = @{}
        )
        InModuleScope Test.WebSession -Parameters @{ FunctionName = $Name; FunctionArguments = $Arguments } {
            param($FunctionName, $FunctionArguments)
            & $FunctionName @FunctionArguments
        }
    }

    # The page failure an action throws; it fails the case when the action
    # throws nothing or throws an error that is no page failure.
    function Get-WebTestFailure {
        param([Parameter(Mandatory)][scriptblock]$Action)
        try {
            $null = & $Action
        } catch {
            $failure = Get-WebFailureData -ErrorRecord $_
            if ($null -eq $failure) { throw }
            return $failure
        }
        throw 'the action threw no page failure'
    }
}

AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
}

Describe 'the SSH tunnel' -Skip:$IsWindows {
    BeforeAll {
        $script:TunnelWork = New-YurunaTestTempDir -Prefix 'yrn-tunnel'
        $script:ShimDir = Join-Path $script:TunnelWork 'bin'
        $script:StandIn = Join-Path $script:TunnelWork 'state'
        $null = New-Item -ItemType Directory -Path $script:ShimDir, $script:StandIn -Force
        # The stand-in counts its runs, records its arguments one per line and
        # its pid, then acts by the word in the file mode.
        $shimText = @'
#!/bin/sh
d='__DIR__'
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/count"
: > "$d/args.$n"
for a in "$@"; do printf '%s\n' "$a" >> "$d/args.$n"; done
echo "$$" > "$d/pid.$n"
mode=$(cat "$d/mode" 2>/dev/null)
hold() {
  printf '%s\n' 'YURUNA_WEB_BROWSER {"ok":true,"event":"holding","id":"t","pid":1}'
  cat >/dev/null
  printf '%s\n' 'YURUNA_WEB_BROWSER {"ok":true,"event":"released","id":"t","pid":1,"stopped":1}'
  exit 0
}
bindfail() {
  echo 'bind [127.0.0.1]:1: Address already in use' >&2
  echo 'Could not request local forwarding.' >&2
  exit 255
}
case "$mode" in
  hold) hold ;;
  bind-once) if [ "$n" -eq 1 ]; then bindfail; fi; hold ;;
  bind-always) bindfail ;;
  denied) echo 'user@host: Permission denied (publickey).' >&2; exit 255 ;;
  refused) printf '%s\n' 'YURUNA_WEB_BROWSER {"ok":false,"kind":"session-not-found","detail":"x"}'; exit 66 ;;
  silent) echo 'stand-in: no route to host' >&2; exec sleep 60 ;;
  stubborn)
    trap '' HUP TERM
    printf '%s\n' 'YURUNA_WEB_BROWSER {"ok":true,"event":"holding","id":"t","pid":1}'
    while :; do sleep 1; done ;;
esac
exit 3
'@
        $shim = Join-Path $script:ShimDir 'ssh'
        Set-Content -LiteralPath $shim -Value ($shimText.Replace('__DIR__', $script:StandIn).Replace("`r`n", "`n")) -NoNewline -Encoding ascii
        & chmod +x $shim
        $script:TunnelSavedPath = Save-YurunaTestEnvironment -Name 'PATH'
        $env:PATH = $script:ShimDir + [IO.Path]::PathSeparator + $script:TunnelSavedPath.PATH
        $script:Tunnels = [System.Collections.Generic.List[object]]::new()
        $script:FixtureHostKey = [string[]]@('-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile="/fixture/pin"',
            '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'HostKeyAlias=yuruna-guest-fixture-vm', '-o', 'CheckHostIP=no')

        function Start-FixtureTunnel {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Starts a tunnel to the stand-in ssh that the AfterEach of the block stops.')]
            param([hashtable]$Extra = @{}, [string[]]$Omit = @())
            $arguments = @{
                VMName = 'fixture-vm'; GuestKey = 'guest.ubuntu.server.26'; Address = '192.0.2.10'; RemotePort = 39001
                RemoteCommand = 'hold-command'; ReadyPattern = '"event":"holding"'; ProbePath = '/json/version'
            }
            foreach ($name in $Omit) { $arguments.Remove($name) }
            foreach ($name in $Extra.Keys) { $arguments[$name] = $Extra[$name] }
            $started = Start-GuestSshTunnel @arguments
            if ($started.Tunnel) { $script:Tunnels.Add($started.Tunnel) }
            return $started
        }
        function Set-StandInMode {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Writes one word into the stand-in folder of the case.')]
            param([string]$Mode)
            Set-Content -LiteralPath (Join-Path $script:StandIn 'mode') -Value $Mode -NoNewline -Encoding ascii
        }
        function Get-StandInLine {
            param([string]$Name)
            $path = Join-Path $script:StandIn $Name
            if (-not (Test-Path -LiteralPath $path)) { return , [string[]]@() }
            return , [string[]]@(Get-Content -LiteralPath $path)
        }
        function Get-StandInPid {
            param([int]$Run = 1)
            return [int](Get-Content -LiteralPath (Join-Path $script:StandIn "pid.$Run") -Raw).Trim()
        }
        function Test-StandInRunning {
            param([int]$Id)
            $stat = (& ps -o stat= -p $Id 2>$null | Out-String).Trim()
            return ([bool]$stat -and -not $stat.StartsWith('Z'))
        }
        function Wait-StandInGone {
            param([int]$Id, [int]$Seconds = 20)
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
                if (-not (Test-StandInRunning -Id $Id)) { return $true }
                Start-Sleep -Milliseconds 100
            }
            return (-not (Test-StandInRunning -Id $Id))
        }
        function Get-ForwardLine {
            param([string[]]$Lines)
            $at = [array]::IndexOf($Lines, '-L')
            if ($at -lt 0) { return '' }
            return $Lines[$at + 1]
        }
    }
    AfterAll {
        Restore-YurunaTestEnvironment -Saved $script:TunnelSavedPath
        Remove-YurunaTestTempDir $script:TunnelWork
    }
    BeforeEach {
        Get-ChildItem -LiteralPath $script:StandIn -Force | Remove-Item -Force -Recurse
        Set-StandInMode -Mode 'hold'
        $script:Tunnels.Clear()
        Mock Get-YurunaSshPrivateKeyPath -ModuleName Test.Ssh { '/fixture/key' }
        Mock Get-YurunaSshHostKeyOption -ModuleName Test.Ssh { $script:FixtureHostKey }
        Mock Invoke-GuestSshTunnelProbe -ModuleName Test.Ssh { @{ StatusCode = 200; Body = '{"Browser":"Fake/1.0"}'; Error = '' } }
    }
    AfterEach {
        foreach ($tunnel in $script:Tunnels) { $null = Stop-GuestSshTunnel -Tunnel $tunnel -GraceMilliseconds 500 }
        foreach ($file in @(Get-ChildItem -LiteralPath $script:StandIn -Filter 'pid.*' -ErrorAction SilentlyContinue)) {
            $leftId = [int](Get-Content -LiteralPath $file.FullName -Raw).Trim()
            if (Test-StandInRunning -Id $leftId) { & kill -9 $leftId 2>$null }
        }
    }

    It 'passes ssh the key, the pinned host key, the keepalives and one loopback forward, in order' {
        $started = Start-FixtureTunnel
        Assert-True $started.Ok "the tunnel did not start: $($started.Code) $($started.Detail)"
        $localPort = $started.Tunnel.LocalPort
        $null = Stop-GuestSshTunnel -Tunnel $started.Tunnel
        try {
            $null = Invoke-GuestSsh -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -User yuuser26 -ResolvedAddress 192.0.2.10 `
                -PrivateKeyPath /fixture/key -Command true -TimeoutSeconds 20
        } finally {
            Clear-ProvenGuestAddress -VMName fixture-vm -Confirm:$false
        }
        $user = Get-GuestSshUser -GuestKey guest.ubuntu.server.26
        $expected = @('-i', '/fixture/key', '-o', 'BatchMode=yes') + $script:FixtureHostKey + @(
            '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4', '-o', 'TCPKeepAlive=yes',
            '-o', 'LogLevel=ERROR', '-o', 'ExitOnForwardFailure=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
            '-T', '-L', "127.0.0.1:${localPort}:127.0.0.1:39001", "$user@192.0.2.10", 'hold-command')
        $first = Get-StandInLine -Name 'args.1'
        Assert-StringEqual -Expected ($expected -join "`n") -Actual ($first -join "`n")
        Assert-StringEqual -Expected 'hold-command' -Actual $first[-1]
        Assert-False (@($first) -ccontains '-N') 'the tunnel must keep its input as the tie to its owner'
        Assert-False (@($first) -ccontains '-n') 'the tunnel must keep its input as the tie to its owner'
        $second = Get-StandInLine -Name 'args.2'
        Assert-True ($second.Count -gt 2) 'Invoke-GuestSsh ran the same stand-in'
        $options = @($second[0..($second.Count - 3)])
        Assert-StringEqual -Expected ($options -join "`n") -Actual (@($first[0..($options.Count - 1)]) -join "`n") -Because 'the tunnel passes every option Invoke-GuestSsh passes for the same guest'
    }

    It 'returns once the remote command reports and the endpoint answers' {
        $started = Start-FixtureTunnel
        Assert-True $started.Ok "the tunnel did not start: $($started.Code) $($started.Detail)"
        Assert-Match 'holding' $started.Tunnel.ReadyLine
        Assert-StringEqual -Expected '{"Browser":"Fake/1.0"}' -Actual $started.Tunnel.ProbeBody
        Should -Invoke Invoke-GuestSshTunnelProbe -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter { $Path -eq '/json/version' }
        $standInPid = Get-StandInPid
        Assert-True (Test-StandInRunning -Id $standInPid) 'the ssh process holds the tunnel'
        Assert-Equal -Expected $standInPid -Actual ([int]$started.Tunnel.ProcessId)
        $forward = Get-ForwardLine -Lines (Get-StandInLine -Name 'args.1')
        Assert-StringEqual -Expected "127.0.0.1:$($started.Tunnel.LocalPort):127.0.0.1:39001" -Actual $forward
    }

    It 'ends the tunnel by closing its input' {
        $started = Start-FixtureTunnel
        Assert-True $started.Ok "the tunnel did not start: $($started.Code) $($started.Detail)"
        $standInPid = Get-StandInPid
        $stop = Stop-GuestSshTunnel -Tunnel $started.Tunnel
        Assert-True $stop.Exited
        Assert-Equal -Expected 0 -Actual $stop.ExitCode
        Assert-False $stop.Forced 'closing the input is the orderly end'
        Assert-Match 'released' $stop.StdOut
        Assert-True (Wait-StandInGone -Id $standInPid) 'the ssh process is gone'
        $again = Stop-GuestSshTunnel -Tunnel $started.Tunnel
        Assert-True ([object]::ReferenceEquals($stop, $again)) 'a second stop returns the first result'
        Assert-StringEqual -Expected '1' -Actual ((Get-StandInLine -Name 'count') -join '') -Because 'a second stop starts nothing'
        $none = Stop-GuestSshTunnel -Tunnel $null
        Assert-True $none.Exited
        Assert-False $none.Forced
    }

    It 'tries another port when ssh loses the bind race' {
        Set-StandInMode -Mode 'bind-once'
        $started = Start-FixtureTunnel
        Assert-True $started.Ok "the tunnel did not start: $($started.Code) $($started.Detail)"
        Assert-Equal -Expected 2 -Actual $started.Attempts
        $firstForward = Get-ForwardLine -Lines (Get-StandInLine -Name 'args.1')
        $secondForward = Get-ForwardLine -Lines (Get-StandInLine -Name 'args.2')
        Assert-NotEqual -NotExpected $firstForward -Actual $secondForward
        Assert-StringEqual -Expected "127.0.0.1:$($started.Tunnel.LocalPort):127.0.0.1:39001" -Actual $secondForward
    }

    It 'gives up after three lost ports' {
        Set-StandInMode -Mode 'bind-always'
        $started = Start-FixtureTunnel
        Assert-False $started.Ok
        Assert-StringEqual -Expected 'local-port-taken' -Actual $started.Code
        Assert-Equal -Expected 3 -Actual $started.Attempts
        Assert-StringEqual -Expected '3' -Actual ((Get-StandInLine -Name 'count') -join '')
    }

    It 'reports a refused login with the client''s own words' {
        Set-StandInMode -Mode 'denied'
        $started = Start-FixtureTunnel
        Assert-StringEqual -Expected 'exited-early' -Actual $started.Code
        Assert-Match 'exit 255' $started.Detail
        Assert-Match 'Permission denied' $started.Detail
    }

    It 'reports the remote command''s refusal' {
        Set-StandInMode -Mode 'refused'
        $started = Start-FixtureTunnel
        Assert-StringEqual -Expected 'exited-early' -Actual $started.Code
        Assert-False $started.Attached
        Assert-Match 'exit 66' $started.Detail
        Assert-Match 'session-not-found' $started.Detail
        Assert-True (@($started.OutputLines) -ccontains 'YURUNA_WEB_BROWSER {"ok":false,"kind":"session-not-found","detail":"x"}') "output: $(@($started.OutputLines) -join ' | ')"
    }

    It 'stops waiting at the startup limit and leaves no process' {
        Set-StandInMode -Mode 'silent'
        $ticks = [ref][long]0
        $clock = { $ticks.Value += 500; $ticks.Value }.GetNewClosure()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $started = Start-FixtureTunnel -Extra @{ Deadline = (New-YurunaDeadline -TotalMilliseconds 2000 -ClockTicks $clock) }
        $watch.Stop()
        Assert-StringEqual -Expected 'not-attached' -Actual $started.Code
        Assert-True ($watch.Elapsed.TotalSeconds -lt 20) "the startup limit took $($watch.Elapsed.TotalSeconds) s of wall time"
        Assert-False $started.Attached
        Assert-True $started.Detail.StartsWith('no ready line:') $started.Detail
        Assert-Match 'no route to host' $started.Detail
        Assert-True (Wait-StandInGone -Id (Get-StandInPid)) 'the ssh process is gone'
    }

    It 'reports an endpoint that never answers and ends the tunnel' {
        $script:TunnelNow = [long]0
        Mock Invoke-GuestSshTunnelProbe -ModuleName Test.Ssh {
            $script:TunnelNow += 1000
            @{ StatusCode = 0; Body = ''; Error = 'Connection reset by peer' }
        }
        $started = Start-FixtureTunnel -Extra @{
            Deadline = (New-YurunaDeadline -TotalMilliseconds 2000 -ClockTicks { $script:TunnelNow })
            Sleep    = { param($Milliseconds) $script:TunnelNow += $Milliseconds }
        }
        Assert-StringEqual -Expected 'endpoint-silent' -Actual $started.Code
        Assert-True $started.Attached 'the ready line arrived before the endpoint was asked'
        Should -Invoke Invoke-GuestSshTunnelProbe -ModuleName Test.Ssh -Times 2 -Exactly
        Assert-Match 'Connection reset by peer' $started.Detail
        Assert-True (Wait-StandInGone -Id (Get-StandInPid)) 'the ssh process is gone'
    }

    It 'forces a tunnel whose far side ignores the end of its input' {
        Set-StandInMode -Mode 'stubborn'
        $started = Start-FixtureTunnel
        Assert-True $started.Ok "the tunnel did not start: $($started.Code) $($started.Detail)"
        $standInPid = Get-StandInPid
        $stop = Stop-GuestSshTunnel -Tunnel $started.Tunnel -GraceMilliseconds 500
        Assert-True $stop.Forced
        Assert-True $stop.Exited
        Assert-True (Wait-StandInGone -Id $standInPid) 'the ssh process is gone'
    }

    It 'starts nothing when no address is known' {
        Mock Get-ProvenGuestAddress -ModuleName Test.Ssh { '' }
        Mock Get-GuestAddress -ModuleName Test.Ssh { 'fixture-vm' }
        $started = Start-FixtureTunnel -Omit 'Address'
        Assert-StringEqual -Expected 'address-unresolved' -Actual $started.Code
        Assert-False (Test-Path -LiteralPath (Join-Path $script:StandIn 'count')) 'no ssh ran'
    }

    It 'ends the tunnel when the process that owns it dies' {
        $sshModule = Join-Path $PSScriptRoot 'Test.Ssh.psm1'
        $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$($sshModule.Replace("'", "''"))' -DisableNameChecking
`$opened = Start-GuestSshTunnel -VMName 192.0.2.10 -GuestKey guest.ubuntu.server.26 -Address 192.0.2.10 -PrivateKeyPath /fixture/key -RemotePort 9 -RemoteCommand hold -ReadyPattern holding
[Console]::Out.WriteLine("OPEN `$(`$opened.Ok)")
[Console]::Out.Flush()
Start-Sleep -Seconds 300
"@
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript)))) {
            $startInfo.ArgumentList.Add($argument)
        }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['NO_COLOR'] = '1'
        $startInfo.Environment['PATH'] = $script:ShimDir + [IO.Path]::PathSeparator + $script:TunnelSavedPath.PATH
        $child = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $errTask = $child.StandardError.ReadToEndAsync()
            $openLine = ''
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $openLine -and $watch.Elapsed.TotalSeconds -lt 120) {
                $lineTask = $child.StandardOutput.ReadLineAsync()
                if (-not $lineTask.Wait(120000)) { break }
                $line = $lineTask.Result
                if ($null -eq $line) { break }
                if ($line.StartsWith('OPEN ')) { $openLine = $line }
            }
            Assert-StringEqual -Expected 'OPEN True' -Actual $openLine -Because "child error output: $(if ($errTask.Wait(1000)) { $errTask.Result })"
            $standInPid = Get-StandInPid
            $child.Kill()
            Assert-True (Wait-StandInGone -Id $standInPid -Seconds 20) 'the tunnel ends with the process that owns it'
        } finally {
            if (-not $child.HasExited) { $child.Kill($true) }
            [void]$child.WaitForExit(10000)
            $child.Dispose()
        }
    }

    It 'starts nothing without an ssh client' {
        $emptyBin = Join-Path $script:TunnelWork 'empty-bin'
        $null = New-Item -ItemType Directory -Path $emptyBin -Force
        $saved = Save-YurunaTestEnvironment -Name 'PATH'
        try {
            $env:PATH = $emptyBin
            $started = Start-FixtureTunnel
        } finally {
            Restore-YurunaTestEnvironment -Saved $saved
        }
        Assert-False $started.Ok
        Assert-StringEqual -Expected 'ssh-missing' -Actual $started.Code
        Assert-Null $started.Tunnel
        Assert-False (Test-Path -LiteralPath (Join-Path $script:StandIn 'count')) 'no ssh ran'
    }

    It 'reports a client the system cannot start' {
        $brokenBin = Join-Path $script:TunnelWork 'broken-bin'
        $null = New-Item -ItemType Directory -Path $brokenBin -Force
        $broken = Join-Path $brokenBin 'ssh'
        Set-Content -LiteralPath $broken -Value "#!/nonexistent/interpreter`n" -NoNewline -Encoding ascii
        & chmod +x $broken
        $saved = Save-YurunaTestEnvironment -Name 'PATH'
        try {
            $env:PATH = $brokenBin
            $started = Start-FixtureTunnel
        } finally {
            Restore-YurunaTestEnvironment -Saved $saved
        }
        Assert-False $started.Ok
        Assert-StringEqual -Expected 'launch-failed' -Actual $started.Code
        Assert-True ([bool]$started.Detail) 'the launch failure names its reason'
        Assert-Null $started.Tunnel
        Assert-False (Test-Path -LiteralPath (Join-Path $script:StandIn 'count')) 'no ssh ran'
    }
}

Describe 'the tunnel probe' {
    It 'returns the status and the body of the endpoint' {
        $responder = Start-YurunaTestHttpResponder -Reply (New-YurunaTestHttpReply -StatusCode 200 -Body '{"Browser":"Fake/1.0"}')
        try {
            $probe = InModuleScope Test.Ssh -Parameters @{ ResponderPort = $responder.Port } {
                param($ResponderPort)
                Invoke-GuestSshTunnelProbe -LocalPort $ResponderPort -Path /json/version -TimeoutMilliseconds 5000
            }
        } finally {
            $requests = @(Stop-YurunaTestHttpResponder $responder)
        }
        Assert-Equal -Expected 200 -Actual $probe.StatusCode
        Assert-StringEqual -Expected '{"Browser":"Fake/1.0"}' -Actual $probe.Body
        Assert-Equal -Expected 1 -Actual $requests.Count
        Assert-True $requests[0].StartsWith('GET /json/version') $requests[0]
        Assert-Match ([regex]::Escape("Host: 127.0.0.1:$($responder.Port)")) $requests[0]
    }

    It 'turns a refused connection into status 0 with the reason' {
        $probe = InModuleScope Test.Ssh -Parameters @{ ClosedPort = (Get-YurunaTestFreePort) } {
            param($ClosedPort)
            Invoke-GuestSshTunnelProbe -LocalPort $ClosedPort -Path /json/version -TimeoutMilliseconds 5000
        }
        Assert-Equal -Expected 0 -Actual $probe.StatusCode
        Assert-True ([bool]$probe.Error) 'the probe names why no answer came'
    }

    It 'reaches the endpoint directly when the environment names a proxy' {
        $responder = Start-YurunaTestHttpResponder -Reply (New-YurunaTestHttpReply -StatusCode 200 -Body '{"Browser":"Fake/1.0"}')
        $child = $null
        try {
            $proxy = "http://127.0.0.1:$(Get-YurunaTestFreePort)"
            $sshModule = Join-Path $PSScriptRoot 'Test.Ssh.psm1'
            $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$($sshModule.Replace("'", "''"))' -DisableNameChecking
`$probe = & (Get-Module Test.Ssh) { Invoke-GuestSshTunnelProbe -LocalPort $($responder.Port) -Path /json/version -TimeoutMilliseconds 5000 }
[Console]::Out.WriteLine("STATUS `$(`$probe.StatusCode)")
"@
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript)))) {
                $startInfo.ArgumentList.Add($argument)
            }
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment['NO_COLOR'] = '1'
            foreach ($name in 'no_proxy', 'NO_PROXY') { [void]$startInfo.Environment.Remove($name) }
            $startInfo.Environment['http_proxy'] = $proxy
            $startInfo.Environment['HTTP_PROXY'] = $proxy
            $child = [System.Diagnostics.Process]::Start($startInfo)
            $outTask = $child.StandardOutput.ReadToEndAsync()
            $errTask = $child.StandardError.ReadToEndAsync()
            Assert-True $child.WaitForExit(120000) 'the child ended within its bound'
            $output = if ($outTask.Wait(5000)) { $outTask.Result } else { '' }
            $errors = if ($errTask.Wait(5000)) { $errTask.Result } else { '' }
        } finally {
            if ($child) {
                if (-not $child.HasExited) { $child.Kill($true); [void]$child.WaitForExit(10000) }
                $child.Dispose()
            }
            $requests = @(Stop-YurunaTestHttpResponder $responder)
        }
        Assert-Match '(?m)^STATUS 200\s*$' $output "child output: $output $errors"
        Assert-Equal -Expected 1 -Actual $requests.Count
    }
}

Describe 'the web session table' {
    BeforeAll {
        $script:StartedLine = 'YURUNA_WEB_BROWSER {"ok":true,"event":"started","id":"w0","port":39001,"wsPath":"/devtools/browser/x","pid":4242,"startTicks":1,"bootId":"deadbeef","dir":"/tmp/yuruna-web-1000/w0.deadbeef","profile":"/tmp/yuruna-web-1000/w0.deadbeef/profile","browser":"/usr/bin/google-chrome-stable","window":"1280,800"}'
        $script:CaseSsh = $null
        $script:CaseTunnel = $null
        function New-FixtureTunnelResult {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory tunnel result.')]
            param()
            return @{
                Ok = $true; Code = ''; Detail = ''; Attempts = 1; Attached = $true; OutputLines = [System.Collections.Generic.List[string]]::new()
                Tunnel = @{ Process = $null; LocalPort = 40001; RemotePort = 39001; ProbeBody = '{"Browser":"Fake/1.0"}'; StopResult = $null }
            }
        }
        function Open-FixtureSession {
            param([string]$VMName = 'vm-a', [string]$OwnerId = 'o1', [hashtable]$Effect)
            $arguments = @{ VMName = $VMName; GuestKey = 'guest.ubuntu.server.26'; OwnerId = $OwnerId }
            if ($Effect) { $arguments['Effect'] = $Effect }
            return (Open-GuestWebSession @arguments 6>$null)
        }
    }
    BeforeEach {
        InModuleScope Test.WebSession { & $script:WebSessionRegistry.Clear }
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:SshCommands = [System.Collections.Generic.List[string]]::new()
        $script:TunnelCalls = [System.Collections.Generic.List[object]]::new()
        $script:CaseSsh = $null
        $script:CaseTunnel = $null
        Mock Invoke-GuestSsh -ModuleName Test.WebSession {
            $script:SshCommands.Add([string]$Command)
            if ([string]$Command -like '* stop --id *') {
                return @{ success = $true; exitCode = 0; addressResolved = $true; transportLost = $false; output = 'YURUNA_WEB_BROWSER {"ok":true,"event":"stopped","stopped":1}' }
            }
            if ($script:CaseSsh) { return $script:CaseSsh }
            return @{ success = $true; exitCode = 0; addressResolved = $true; transportLost = $false; output = $script:StartedLine }
        }
        Mock Start-GuestSshTunnel -ModuleName Test.WebSession {
            $script:TunnelCalls.Add(@{ RemoteCommand = [string]$RemoteCommand; RemotePort = $RemotePort; ProbePath = [string]$ProbePath })
            if ($script:CaseTunnel) { return $script:CaseTunnel }
            return (New-FixtureTunnelResult)
        }
        Mock Stop-GuestSshTunnel -ModuleName Test.WebSession {
            $script:Calls.Add('tunnel')
            @{ Exited = $true; ExitCode = 0; Forced = $false; StdOut = ''; StdErr = '' }
        }
        Mock Test-GuestSshTunnel -ModuleName Test.WebSession { $true }
        Mock Close-WebCdp -ModuleName Test.WebSession { $script:Calls.Add('cdp') }
    }

    It 'opens one session per VM and numbers it' {
        $before = [int](InModuleScope Test.WebSession { & $script:WebSessionCounter.Get 'Generation' })
        $opened = Open-FixtureSession -VMName 'vm-a' -OwnerId 'o1'
        Assert-True $opened.Ok "the open failed: $($opened.Code) $($opened.Detail)"
        $session = $opened.Session
        Assert-Equal -Expected ($before + 1) -Actual $session.Generation
        Assert-True ([object]::ReferenceEquals((Get-GuestWebSession -VMName 'vm-a'), $session)) 'the table holds the returned session'
        Assert-StringEqual -Expected 'open' -Actual $session.State
        Assert-Equal -Expected 40001 -Actual $session.LocalPort
        Assert-StringEqual -Expected 'Fake/1.0' -Actual $session.Product
        Assert-StringEqual -Expected 'o1' -Actual $session.OwnerId
        Assert-Null $session.Cdp
        $startCommand = @($script:SshCommands)[0]
        Assert-Match " start --id 'w" $startCommand
        $id = [regex]::Match($startCommand, "--id '([^']+)'").Groups[1].Value
        Assert-Equal -Expected 1 -Actual $script:TunnelCalls.Count
        $tunnelCall = $script:TunnelCalls[0]
        Assert-Match ([regex]::Escape(" hold --id '$id'")) $tunnelCall.RemoteCommand
        Assert-Equal -Expected 39001 -Actual ([int]$tunnelCall.RemotePort)
        Assert-StringEqual -Expected '/json/version' -Actual $tunnelCall.ProbePath
    }

    It 'names both ports as the digits ssh and the launcher use' {
        $lines = @(Open-GuestWebSession -VMName 'vm-a' -GuestKey 'guest.ubuntu.server.26' -OwnerId 'o1' 6>&1 |
                Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                ForEach-Object { [string]$_.MessageData })
        $opened = @($lines | Where-Object { $_ -like '*vm-a*Fake/1.0*' })
        Assert-Equal -Expected 1 -Actual $opened.Count "one session line, got: $($lines -join ' | ')"
        Assert-Match 'port 39001,' $opened[0]
        Assert-Match '127\.0\.0\.1:40001\.' $opened[0]
    }

    It 'marks the step as dispatched before the launcher runs' {
        $script:Effect = @{ Dispatched = $false }
        $script:SawDispatched = $null
        Mock Invoke-GuestSsh -ModuleName Test.WebSession {
            $script:SawDispatched = $script:Effect.Dispatched
            @{ success = $true; exitCode = 0; addressResolved = $true; transportLost = $false; output = $script:StartedLine }
        }
        $opened = Open-FixtureSession -Effect $script:Effect
        Assert-True $opened.Ok
        Assert-True ($script:SawDispatched -eq $true) 'the launcher ran with the step marked as dispatched'
        $null = Close-GuestWebSession -All -Reason 'sequence-end'
        $script:Effect = @{ Dispatched = $false }
        Mock Invoke-GuestSsh -ModuleName Test.WebSession {
            @{ success = $false; exitCode = -2; addressResolved = $false; transportLost = $false; output = '' }
        }
        $refused = Open-FixtureSession -Effect $script:Effect 3>$null
        Assert-False $refused.Ok
        Assert-True ($script:Effect.Dispatched -eq $false) 'nothing ran, so nothing was dispatched'
    }

    It 'closes the earlier session when the same VM is opened again' {
        $first = Open-FixtureSession
        $second = Open-FixtureSession
        Assert-StringEqual -Expected 'tunnel' -Actual ($script:Calls -join ',')
        $entries = Get-GuestWebSessionList
        Assert-Equal -Expected 1 -Actual $entries.Count
        Assert-True ($second.Session.Generation -gt $first.Session.Generation)
        Assert-Equal -Expected $second.Session.Generation -Actual (Get-GuestWebSession -VMName 'vm-a').Generation
    }

    It 'closes only the sessions of the owner that ends' {
        $null = Open-FixtureSession -VMName 'vm-a' -OwnerId 'o1'
        $null = Open-FixtureSession -VMName 'vm-b' -OwnerId 'o2'
        Assert-Equal -Expected 1 -Actual (Close-GuestWebSession -OwnerId 'o1' -Reason 'sequence-end')
        Assert-Null (Get-GuestWebSession -VMName 'vm-a')
        Assert-NotNull (Get-GuestWebSession -VMName 'vm-b')
        Assert-Equal -Expected 0 -Actual (Close-GuestWebSession -OwnerId '' -Reason 'sequence-end')
        Assert-NotNull (Get-GuestWebSession -VMName 'vm-b')
    }

    It 'does not close a newer session through an old generation' {
        $first = Open-FixtureSession
        $null = Open-FixtureSession
        Assert-Equal -Expected 0 -Actual (Close-GuestWebSession -VMName 'vm-a' -Generation $first.Session.Generation -Reason 'vm-stop')
        Assert-NotNull (Get-GuestWebSession -VMName 'vm-a')
    }

    It 'closes the page connection before it stops the tunnel' {
        $opened = Open-FixtureSession
        $opened.Session.Cdp = @{ Fixture = $true }
        $script:Calls.Clear()
        Assert-Equal -Expected 1 -Actual (Close-GuestWebSession -VMName 'vm-a' -Reason 'web-close')
        Assert-StringEqual -Expected 'cdp,tunnel' -Actual ($script:Calls -join ',')
        Assert-StringEqual -Expected 'closed' -Actual $opened.Session.State
        Assert-StringEqual -Expected 'web-close' -Actual $opened.Session.CloseReason
    }

    It 'stops the tunnel even when the page connection cannot be closed' {
        Mock Close-WebCdp -ModuleName Test.WebSession { throw 'fixture: the page connection does not close' }
        $opened = Open-FixtureSession
        $opened.Session.Cdp = @{ Fixture = $true }
        $script:Calls.Clear()
        Assert-Equal -Expected 1 -Actual (Close-GuestWebSession -VMName 'vm-a' -Reason 'web-close')
        Assert-True ($script:Calls -contains 'tunnel') 'the tunnel stopped'
        Assert-Null (Get-GuestWebSession -VMName 'vm-a')
    }

    It 'finds the same session after the module is imported again' {
        $opened = Open-FixtureSession
        Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'Test.Ssh.psm1') -Force -Global -DisableNameChecking
        Assert-True ([object]::ReferenceEquals((Get-GuestWebSession -VMName 'vm-a'), $opened.Session)) 'a re-import finds the session it left'
        Assert-Equal -Expected 1 -Actual (Get-GuestWebSessionList).Count
        Mock Stop-GuestSshTunnel -ModuleName Test.WebSession {
            $script:Calls.Add('tunnel')
            @{ Exited = $true; ExitCode = 0; Forced = $false; StdOut = ''; StdErr = '' }
        }
        Assert-Equal -Expected 1 -Actual (Close-GuestWebSession -VMName 'vm-a' -Reason 'web-close')
    }

    It 'reports <Case> and leaves no session' -ForEach @(
        @{ Case = 'an address that is not found'; Shape = 'ssh-unresolved'; Kind = 'address_unresolved'; Code = 'address-unresolved'; SshCalls = 1; LauncherKind = ''; Issued = $false; TunnelStopped = $false }
        @{ Case = 'a launcher refusal'; Shape = 'ssh-refused'; Kind = 'browser_unavailable'; Code = 'launcher-refused'; SshCalls = 1; LauncherKind = 'browser-not-found'; Issued = $true; TunnelStopped = $false }
        @{ Case = 'a launcher call without a report'; Shape = 'ssh-transport'; Kind = 'transport'; Code = 'launcher-transport'; SshCalls = 2; LauncherKind = ''; Issued = $true; TunnelStopped = $false }
        @{ Case = 'a tunnel that never attached'; Shape = 'tunnel-not-attached'; Kind = 'transport'; Code = 'tunnel-not-attached'; SshCalls = 2; LauncherKind = ''; Issued = $true; TunnelStopped = $false }
        @{ Case = 'a hold that refused the session'; Shape = 'tunnel-refused'; Kind = 'browser_unavailable'; Code = 'tunnel-exited-early'; SshCalls = 2; LauncherKind = 'session-not-found'; Issued = $true; TunnelStopped = $false }
        @{ Case = 'an endpoint that is not JSON'; Shape = 'probe-not-json'; Kind = 'protocol'; Code = 'endpoint-not-json'; SshCalls = 1; LauncherKind = ''; Issued = $true; TunnelStopped = $true }
    ) {
        switch ($Shape) {
            'ssh-unresolved' { $script:CaseSsh = @{ success = $false; exitCode = -2; addressResolved = $false; transportLost = $false; output = '' } }
            'ssh-refused' { $script:CaseSsh = @{ success = $false; exitCode = 127; addressResolved = $true; transportLost = $false; output = 'YURUNA_WEB_BROWSER {"ok":false,"kind":"browser-not-found","detail":"no browser"}' } }
            'ssh-transport' { $script:CaseSsh = @{ success = $false; exitCode = 255; addressResolved = $true; transportLost = $false; output = '' } }
            'tunnel-not-attached' {
                $result = New-FixtureTunnelResult
                $result.Ok = $false; $result.Code = 'not-attached'; $result.Detail = 'no ready line:'; $result.Attached = $false; $result.Tunnel = $null
                $script:CaseTunnel = $result
            }
            'tunnel-refused' {
                $result = New-FixtureTunnelResult
                $result.Ok = $false; $result.Code = 'exited-early'; $result.Detail = 'exit 66:'; $result.Attached = $false; $result.Tunnel = $null
                $result.OutputLines.Add('YURUNA_WEB_BROWSER {"ok":false,"kind":"session-not-found","detail":"x"}')
                $script:CaseTunnel = $result
            }
            'probe-not-json' {
                $result = New-FixtureTunnelResult
                $result.Tunnel.ProbeBody = 'hello'
                $script:CaseTunnel = $result
            }
        }
        $warnings = $null
        $opened = Open-GuestWebSession -VMName 'vm-a' -GuestKey 'guest.ubuntu.server.26' -OwnerId 'o1' -WarningVariable warnings -WarningAction SilentlyContinue 6>$null
        Assert-False $opened.Ok
        Assert-StringEqual -Expected $Kind -Actual $opened.Kind
        Assert-StringEqual -Expected $Code -Actual $opened.Code
        Should -Invoke Invoke-GuestSsh -ModuleName Test.WebSession -Times $SshCalls -Exactly
        Assert-StringEqual -Expected $LauncherKind -Actual ([string]$opened.LauncherKind)
        Assert-Equal -Expected $Issued -Actual ([bool]$opened.BrowserStartIssued)
        if ($TunnelStopped) { Assert-True ($script:Calls -contains 'tunnel') 'the tunnel of a bad endpoint is stopped' }
        Assert-Equal -Expected 1 -Actual @($warnings).Count -Because 'one warning names the failed open'
        Assert-Null (Get-GuestWebSession -VMName 'vm-a')
    }

    It 'tells a dead browser from a dead tunnel' {
        Mock Test-GuestSshTunnel -ModuleName Test.WebSession { $false }
        Mock Stop-GuestSshTunnel -ModuleName Test.WebSession {
            @{ Exited = $true; ExitCode = 70; Forced = $false; StdOut = 'YURUNA_WEB_BROWSER {"ok":false,"event":"browser-exited","kind":"browser-exited","detail":"x"}'; StdErr = '' }
        }
        $dead = Test-GuestWebSession -Session @{ State = 'open'; Tunnel = @{ Process = $null } }
        Assert-False $dead.Alive
        Assert-StringEqual -Expected 'browser-exited' -Actual $dead.Code
        Mock Stop-GuestSshTunnel -ModuleName Test.WebSession {
            @{ Exited = $true; ExitCode = 255; Forced = $false; StdOut = ''; StdErr = 'Connection closed by remote host' }
        }
        $lost = Test-GuestWebSession -Session @{ State = 'open'; Tunnel = @{ Process = $null } }
        Assert-False $lost.Alive
        Assert-StringEqual -Expected 'tunnel-exited' -Actual $lost.Code
    }

    It 'builds a command that leaves the session''s input to the launcher' {
        $holdText = InModuleScope Test.WebSession { Get-GuestWebBrowserCommand -Verb hold -Id 'w1' }
        Assert-Match '^bash -c "\$\(printf ''%s'' ''[A-Za-z0-9+/=]+'' \| base64 -d\)" yuruna-web-browser hold --id ''w1''$' $holdText
        $encoded = [regex]::Match($holdText, "printf '%s' '([A-Za-z0-9+/=]+)'").Groups[1].Value
        $launcher = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'automation' -AdditionalChildPath 'yuruna-web-browser.sh'
        Assert-StringEqual -Expected ([Convert]::ToBase64String([IO.File]::ReadAllBytes($launcher))) -Actual ([Convert]::ToBase64String([Convert]::FromBase64String($encoded)))
        Assert-Throw { InModuleScope Test.WebSession { Get-GuestWebBrowserCommand -Verb hold -Id 'a b' } }
    }
}

Describe 'a web session ends with its sequence' {
    BeforeAll {
        $script:SequenceFile = Join-Path $TestDrive 'web-fixture.yml'
        Set-Content -LiteralPath $script:SequenceFile -Value 'fixture: mocked parser'
        $script:LifetimeStartedLine = 'YURUNA_WEB_BROWSER {"ok":true,"event":"started","id":"w0","port":39001,"wsPath":"/devtools/browser/x","pid":4242,"startTicks":1,"bootId":"deadbeef","dir":"/tmp/yuruna-web-1000/w0.deadbeef","profile":"/tmp/yuruna-web-1000/w0.deadbeef/profile","browser":"/usr/bin/google-chrome-stable","window":"1280,800"}'
        Register-SequenceAction -Name webFixture -ReplaySafety observe -CapturesOwnFailureScreenshot $true -Handler {
            param($c)
            $null = Open-GuestWebSession -VMName $c.VMName -GuestKey $c.GuestKey -OwnerId $c.SequenceInvocationId 6>$null
            if ($c.Step.restart) {
                $restart = [System.Management.Automation.RuntimeException]::new('YurunaCycleRestart: fixture restart')
                $restart.Data['YurunaCycleRestart'] = $true
                throw $restart
            }
            return (-not [bool]$c.Step.fail)
        }
    }
    AfterAll {
        # The fixture verb leaves the registry, so a later block that walks the
        # page verbs by their prefix finds only the registered ones.
        InModuleScope Test.SequenceAction { [void]$script:SequenceActionRegistry.Store[0].Remove('webFixture') }
    }
    BeforeEach {
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        Mock Read-SequenceFile -ModuleName Test.SequenceEngine { $script:FixtureSequence }
        InModuleScope Test.WebSession { & $script:WebSessionRegistry.Clear }
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-GuestSsh -ModuleName Test.WebSession {
            @{ success = $true; exitCode = 0; addressResolved = $true; transportLost = $false; output = $script:LifetimeStartedLine }
        }
        Mock Start-GuestSshTunnel -ModuleName Test.WebSession {
            @{
                Ok = $true; Code = ''; Detail = ''; Attempts = 1; Attached = $true; OutputLines = [System.Collections.Generic.List[string]]::new()
                Tunnel = @{ Process = $null; LocalPort = 40001; RemotePort = 39001; ProbeBody = '{"Browser":"Fake/1.0"}'; StopResult = $null }
            }
        }
        Mock Stop-GuestSshTunnel -ModuleName Test.WebSession {
            $script:Calls.Add('tunnel')
            @{ Exited = $true; ExitCode = 0; Forced = $false; StdOut = ''; StdErr = '' }
        }
        Mock Test-GuestSshTunnel -ModuleName Test.WebSession { $true }
    }

    It 'closes the session a passing sequence opened' {
        $script:FixtureSequence = @{ steps = @(@{ action = 'webFixture' }) }
        $ok = Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile
        Assert-True ($ok -eq $true) 'the sequence passed'
        Assert-Equal -Expected 0 -Actual (Get-GuestWebSessionList).Count
        Assert-True ($script:Calls -contains 'tunnel') 'the tunnel was stopped'
    }

    It 'closes it when a step fails' {
        $script:FixtureSequence = @{ steps = @(@{ action = 'webFixture' }, @{ action = 'webFixture'; fail = $true }) }
        $ok = Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile 3>$null
        Assert-True ($ok -eq $false) 'the sequence failed'
        Assert-Equal -Expected 0 -Actual (Get-GuestWebSessionList).Count
    }

    It 'closes it when a handler asks for a cycle restart' {
        $script:FixtureSequence = @{ steps = @(@{ action = 'webFixture'; restart = $true }) }
        Assert-Throw { Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile 3>$null }
        Assert-Equal -Expected 0 -Actual (Get-GuestWebSessionList).Count
    }

    It 'leaves it open across a continuation call' {
        $script:FixtureSequence = @{ steps = @(@{ action = 'webFixture' }) }
        $null = Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -Continuation
        $entry = Get-GuestWebSession -VMName never-a-real-vm
        Assert-NotNull $entry 'a continuation call leaves the session to its caller'
        Assert-StringEqual -Expected 'open' -Actual $entry.State
        $null = Close-GuestWebSession -All -Reason 'sequence-end'
    }

    It 'leaves another owner''s session alone' {
        $other = Open-GuestWebSession -VMName other-vm -GuestKey guest.ubuntu.server.26 -OwnerId other 6>$null
        Assert-True $other.Ok
        $script:FixtureSequence = @{ steps = @(@{ action = 'webFixture' }) }
        $null = Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile
        Assert-True ([object]::ReferenceEquals((Get-GuestWebSession -VMName other-vm), $other.Session)) 'the other owner''s session is still there'
        Assert-Null (Get-GuestWebSession -VMName never-a-real-vm)
        $null = Close-GuestWebSession -All -Reason 'sequence-end'
    }
}

Describe 'a web session ends before its guest does' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1') -Force -Global -DisableNameChecking
        $script:GuestStub = @{ State = 'running'; Words = [System.Collections.Generic.List[string]]::new() }
        # Dot-sourced into the module, as the handler suite does, so they shadow
        # the host contract and the session close for this module only.
        . (Get-Module Test.SequenceHandler) {
            function Close-GuestWebSession {
                param([string]$VMName = '', [int]$Generation, [string]$OwnerId = '', [switch]$All, [string]$Reason)
                $null = $Generation, $OwnerId, $All
                $script:GuestStub.Words.Add("web:${VMName}:$Reason")
                return 1
            }
            function Get-VMState {
                param([string]$VMName)
                $null = $VMName
                $script:GuestStub.Words.Add('state')
                return $script:GuestStub.State
            }
            function Stop-VM {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$VMName, [switch]$Force, [int]$ShutdownTimeoutSeconds, [switch]$NoForce)
                $null = $Force, $ShutdownTimeoutSeconds, $NoForce
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub shutdown request')) { return $false }
                $script:GuestStub.Words.Add('stop')
                $script:GuestStub.State = 'stopped'
                return $true
            }
            function Stop-VMForce {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$VMName, [int]$StopTimeoutSeconds)
                $null = $StopTimeoutSeconds
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub forced stop')) { return $false }
                $script:GuestStub.Words.Add('force')
                $script:GuestStub.State = 'stopped'
                return $true
            }
            function Start-VM {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([hashtable])]
                param([string]$VMName)
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub start')) { return @{ success = $false } }
                $script:GuestStub.Words.Add('start')
                $script:GuestStub.State = 'running'
                return @{ success = $true; errorMessage = $null }
            }
            function Restart-VMConsole {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([bool])]
                param([string]$VMName)
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub console refresh')) { return $false }
                $script:GuestStub.Words.Add('console')
                return $true
            }
            function Save-VMDiskSnapshot {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([bool])]
                param([string]$VMName, [string]$Id)
                if (-not $PSCmdlet.ShouldProcess("$VMName/$Id", 'stub snapshot save')) { return $false }
                $script:GuestStub.Words.Add('save')
                return $true
            }
            function Restore-VMDiskSnapshot {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([bool])]
                param([string]$VMName, [string]$Id)
                if (-not $PSCmdlet.ShouldProcess("$VMName/$Id", 'stub snapshot restore')) { return $false }
                $script:GuestStub.Words.Add('restore')
                return $true
            }
            function Test-VMDiskSnapshot {
                param([string]$VMName, [string]$Id)
                $null = $VMName, $Id
                $script:GuestStub.Words.Add('snapshot-check')
                return $true
            }
            function Test-SnapshotManifestMatch {
                param([string]$VMName, [string]$SnapshotId, [string]$HostType)
                $null = $VMName, $SnapshotId, $HostType
                $script:GuestStub.Words.Add('manifest-check')
                return @{ Status = 'match' }
            }
            function Write-SnapshotManifest {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([string])]
                param([string]$VMName, [string]$SnapshotId, [string]$HostType, [hashtable]$Extra)
                $null = $HostType, $Extra
                if (-not $PSCmdlet.ShouldProcess("$VMName/$SnapshotId", 'stub manifest write')) { return '' }
                $script:GuestStub.Words.Add('manifest')
                return 'manifest.json'
            }
            function Move-GuestHostKeyPin {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$VMName, [string]$NewVMName)
                if ($PSCmdlet.ShouldProcess($NewVMName, 'stub pin move')) { $script:GuestStub.Words.Add('move-pin') }
                $null = $VMName
            }
        }
        & (Get-Module Test.SequenceHandler) { $script:GuestStub = $args[0] } $script:GuestStub
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }
    BeforeEach { $script:GuestStub.Words.Clear() }

    It 'closes the session before <Place>' -ForEach @(
        @{ Place = 'the stopVm request'; Verb = 'stopVm'; State = 'running'; StepId = ''; Word = 'web:test-vm:vm-stop'; Before = 'stop'; First = $false }
        @{ Place = 'the startVm boundary'; Verb = 'startVm'; State = 'stopped'; StepId = ''; Word = 'web:test-vm:vm-stop'; Before = 'start'; First = $true }
        @{ Place = 'the saveDiskSnapshot rename'; Verb = 'saveDiskSnapshot'; State = 'running'; StepId = 'snap1'; Word = 'web:test-vm:vm-rename'; Before = 'save'; First = $false }
        @{ Place = 'the loadDiskSnapshot restore'; Verb = 'loadDiskSnapshot'; State = 'running'; StepId = 'snap1'; Word = 'web:test-vm:vm-restore'; Before = 'restore'; First = $false }
        @{ Place = 'a cold power cycle'; Verb = ''; State = 'running'; StepId = ''; Word = 'web:test-vm:vm-power-cycle'; Before = 'force'; First = $false }
    ) {
        $script:GuestStub.State = $State
        $step = if ($StepId) { @{ id = $StepId } } else { @{ timeoutSeconds = 1; frameIntervalSeconds = 0 } }
        $context = @{
            Step = $step; StepNum = 3; StepCount = 9; Description = 'web session close fixture'
            VMName = 'test-vm'; HostType = 'host.ubuntu.kvm'; GuestKey = 'guest.ubuntu.server.26'
            LogDir = $TestDrive; ScreenshotDir = $TestDrive
            ExpandVariable = { param($v) $v }; Vars = @{}
        }
        if ($Verb) {
            $null = & (Get-SequenceAction -Name $Verb).Handler $context 3>$null 6>$null
        } else {
            $null = & (Get-Module Test.SequenceHandler) { param($ColdContext) Invoke-SequenceColdPowerCycle -Context $ColdContext } $context 3>$null 6>$null
        }
        $words = @($script:GuestStub.Words)
        $closeAt = [array]::IndexOf($words, $Word)
        $guestAt = [array]::IndexOf($words, $Before)
        Assert-True ($closeAt -ge 0) "no close: $($words -join ',')"
        Assert-True ($guestAt -gt $closeAt) "the close must precede '$Before': $($words -join ',')"
        if ($First) { Assert-Equal -Expected 0 -Actual $closeAt -Because "words: $($words -join ',')" }
    }
}

Describe 'a guest stop without the session module' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1') -Force -Global -DisableNameChecking
        $script:BareStub = @{ State = 'running'; Words = [System.Collections.Generic.List[string]]::new() }
        . (Get-Module Test.SequenceHandler) {
            function Get-VMState {
                param([string]$VMName)
                $null = $VMName
                $script:BareStub.Words.Add('state')
                return $script:BareStub.State
            }
            function Stop-VM {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$VMName, [switch]$Force, [int]$ShutdownTimeoutSeconds, [switch]$NoForce)
                $null = $Force, $ShutdownTimeoutSeconds, $NoForce
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub shutdown request')) { return $false }
                $script:BareStub.Words.Add('stop')
                $script:BareStub.State = 'stopped'
                return $true
            }
            function Stop-VMForce {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$VMName, [int]$StopTimeoutSeconds)
                $null = $StopTimeoutSeconds
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub forced stop')) { return $false }
                $script:BareStub.Words.Add('force')
                $script:BareStub.State = 'stopped'
                return $true
            }
        }
        & (Get-Module Test.SequenceHandler) { $script:BareStub = $args[0] } $script:BareStub
        Remove-Module Test.WebSession -Force
    }
    AfterAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Force -Global -DisableNameChecking
        Remove-Module Test.SequenceHandler -Force
    }

    It 'asks nothing of a session module that was never loaded' {
        Assert-Null (Get-Command Close-GuestWebSession -ErrorAction SilentlyContinue)
        $context = @{
            Step = @{ timeoutSeconds = 1; frameIntervalSeconds = 0 }; StepNum = 3; StepCount = 9; Description = 'bare stop fixture'
            VMName = 'test-vm'; HostType = 'host.ubuntu.kvm'; GuestKey = 'guest.ubuntu.server.26'
            LogDir = $TestDrive; ScreenshotDir = $TestDrive
            ExpandVariable = { param($v) $v }; Vars = @{}
        }
        $stopped = & (Get-SequenceAction -Name stopVm).Handler $context 3>$null 6>$null
        Assert-True ($stopped -eq $true) "words: $(@($script:BareStub.Words) -join ',')"
        Assert-False (@($script:BareStub.Words | Where-Object { $_ -like 'web:*' }).Count -gt 0) 'no session close was asked'
    }
}

Describe 'the DevTools endpoint address' {
    It 'takes only the path of the URL that names <ReportedHost> and joins it to the local port' -ForEach @(
        @{ ReportedHost = '127.0.0.1:9222' }
        @{ ReportedHost = 'localhost:9222' }
        @{ ReportedHost = '[::1]:9222' }
    ) {
        $document = @{ webSocketDebuggerUrl = "ws://$ReportedHost/devtools/browser/abc-123" }
        $uri = Invoke-WebTestPrivate -Name 'ConvertTo-WebCdpSocketUri' -Arguments @{ VersionDocument = $document; Port = 40123 }
        Assert-True ([string]::Equals('ws://127.0.0.1:40123/devtools/browser/abc-123', $uri.AbsoluteUri, [StringComparison]::Ordinal)) "got $uri"
    }

    It 'refuses a version document without a browser WebSocket path' {
        foreach ($document in @(
                @{ Browser = 'Fake/1.0' }
                @{ webSocketDebuggerUrl = 'wss://127.0.0.1:9222/devtools/browser/abc-123' }
                @{ webSocketDebuggerUrl = 'ws://127.0.0.1:9222/devtools/page/1' }
            )) {
            $failure = Get-WebTestFailure { Invoke-WebTestPrivate -Name 'ConvertTo-WebCdpSocketUri' -Arguments @{ VersionDocument = $document; Port = 40123 } }
            Assert-StringEqual -Expected 'protocol' -Actual $failure.Kind -Because ($document | ConvertTo-Json -Compress)
        }
    }
}

Describe 'the socket transport' {
    BeforeAll {
        function New-WebTestSocketEnd {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Opens a loopback WebSocket pair for one case, which the case disposes.')]
            param([long]$MaxMessageBytes = 33554432)
            $pair = New-YurunaTestSocketPair
            $peer = [System.Net.WebSockets.WebSocket]::CreateFromStream($pair.Server.GetStream(), $true, [NullString]::Value, [TimeSpan]::Zero)
            $client = [System.Net.WebSockets.WebSocket]::CreateFromStream($pair.Client.GetStream(), $false, [NullString]::Value, [TimeSpan]::Zero)
            $transport = Invoke-WebTestPrivate -Name 'New-WebCdpSocketTransport' -Arguments @{ Socket = $client; MaxMessageBytes = $MaxMessageBytes }
            return @{ Pair = $pair; Peer = $peer; Client = $client; Transport = $transport }
        }

        function Close-WebTestSocketEnd {
            param([hashtable]$Ends)
            if ($null -eq $Ends) { return }
            foreach ($disposable in @($Ends.Peer, $Ends.Client, $Ends.Pair.Server, $Ends.Pair.Client)) {
                if ($null -ne $disposable) { $disposable.Dispose() }
            }
        }

        # Starts sending one frame from the peer; the case waits on the task
        # after it read, so a message larger than the socket buffers is not
        # blocked by a reader that has not started.
        function Send-WebTestFrame {
            param(
                [Parameter(Mandatory)][System.Net.WebSockets.WebSocket]$Socket,
                [Parameter(Mandatory)][byte[]]$Bytes,
                [bool]$EndOfMessage = $true
            )
            return $Socket.SendAsync([ArraySegment[byte]]::new($Bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $EndOfMessage, [System.Threading.CancellationToken]::None)
        }

        function Read-WebTestTransport {
            param([hashtable]$Transport, [int]$Milliseconds = 5000)
            Invoke-WebTestPrivate -Name 'Read-WebCdpTransport' -Arguments @{ Transport = $Transport; TimeoutMs = $Milliseconds }
        }

        $script:Utf8 = [System.Text.UTF8Encoding]::new($false)
    }

    It 'returns nothing on an idle socket and keeps the pending receive' {
        $ends = New-WebTestSocketEnd
        try {
            Assert-Null (Read-WebTestTransport -Transport $ends.Transport -Milliseconds 50) 'the first idle read'
            Assert-Null (Read-WebTestTransport -Transport $ends.Transport -Milliseconds 50) 'the second idle read'
            Assert-NotNull $ends.Transport.Pending 'the receive stays pending for the next read'
            Assert-StringEqual -Expected 'Open' -Actual $ends.Client.State
            $sending = Send-WebTestFrame -Socket $ends.Peer -Bytes ($script:Utf8.GetBytes('{"id":1,"result":{}}'))
            $text = Read-WebTestTransport -Transport $ends.Transport
            Assert-True $sending.Wait(5000) 'the peer sent'
            Assert-True ([string]::Equals('{"id":1,"result":{}}', $text, [StringComparison]::Ordinal)) "read $text"
        } finally { Close-WebTestSocketEnd $ends }
    }

    It 'joins a message sent in three fragments, also inside a character' {
        $ends = New-WebTestSocketEnd
        try {
            $whole = '{"id":1,"result":{"text":"caf' + [char]0x00E9 + '"}}'
            $first = $script:Utf8.GetBytes('{"id":1,')
            $middle = $script:Utf8.GetBytes('"result":{"text":"caf') + [byte[]]@(0xC3)
            $last = [byte[]]@(0xA9) + $script:Utf8.GetBytes('"}}')
            Assert-True (Send-WebTestFrame -Socket $ends.Peer -Bytes $first -EndOfMessage $false).Wait(5000) 'first fragment'
            Assert-True (Send-WebTestFrame -Socket $ends.Peer -Bytes ([byte[]]$middle) -EndOfMessage $false).Wait(5000) 'second fragment'
            Assert-True (Send-WebTestFrame -Socket $ends.Peer -Bytes ([byte[]]$last)).Wait(5000) 'third fragment'
            $text = Read-WebTestTransport -Transport $ends.Transport
            Assert-True ([string]::Equals($whole, $text, [StringComparison]::Ordinal)) "read $text"
        } finally { Close-WebTestSocketEnd $ends }
    }

    It 'returns two waiting messages one per call' {
        $ends = New-WebTestSocketEnd
        try {
            Assert-True (Send-WebTestFrame -Socket $ends.Peer -Bytes ($script:Utf8.GetBytes('{"id":1,"result":{}}'))).Wait(5000) 'first message'
            Assert-True (Send-WebTestFrame -Socket $ends.Peer -Bytes ($script:Utf8.GetBytes('{"id":2,"result":{}}'))).Wait(5000) 'second message'
            Assert-StringEqual -Expected '{"id":1,"result":{}}' -Actual (Read-WebTestTransport -Transport $ends.Transport)
            Assert-StringEqual -Expected '{"id":2,"result":{}}' -Actual (Read-WebTestTransport -Transport $ends.Transport)
        } finally { Close-WebTestSocketEnd $ends }
    }

    It 'reads a message longer than its buffer' {
        $ends = New-WebTestSocketEnd
        try {
            $whole = '{"id":3,"result":{"text":"' + ('x' * 200000) + '"}}'
            $sending = Send-WebTestFrame -Socket $ends.Peer -Bytes ($script:Utf8.GetBytes($whole))
            $text = Read-WebTestTransport -Transport $ends.Transport
            Assert-True $sending.Wait(5000) 'the peer sent'
            Assert-Equal -Expected $whole.Length -Actual ([string]$text).Length
            Assert-True ([string]::Equals($whole, $text, [StringComparison]::Ordinal)) 'the whole text arrived'
        } finally { Close-WebTestSocketEnd $ends }
    }

    It 'discards a reply over the limit, answers it as error -32099 and stays open' {
        $ends = New-WebTestSocketEnd -MaxMessageBytes 1024
        try {
            $large = '{"id":7,"result":{"text":"' + ('y' * (5000 - 30)) + '"}}'
            $sending = Send-WebTestFrame -Socket $ends.Peer -Bytes ($script:Utf8.GetBytes($large))
            $first = Read-WebTestTransport -Transport $ends.Transport
            Assert-True $sending.Wait(5000) 'the peer sent the large reply'
            $answer = ConvertFrom-Json -InputObject $first -AsHashtable
            Assert-Equal -Expected 7 -Actual $answer['id']
            Assert-Equal -Expected -32099 -Actual $answer['error']['code']
            Assert-True (Send-WebTestFrame -Socket $ends.Peer -Bytes ($script:Utf8.GetBytes('{"id":8,"result":{}}'))).Wait(5000) 'the next reply'
            Assert-StringEqual -Expected '{"id":8,"result":{}}' -Actual (Read-WebTestTransport -Transport $ends.Transport)
            Assert-Equal -Expected 1 -Actual $ends.Transport.Oversize
            Assert-StringEqual -Expected 'Open' -Actual $ends.Client.State
        } finally { Close-WebTestSocketEnd $ends }
    }

    It 'drops an event over the limit and delivers the next message' {
        $ends = New-WebTestSocketEnd -MaxMessageBytes 1024
        try {
            $large = '{"method":"Test.large","params":{"text":"' + ('z' * 5000) + '"}}'
            Assert-True (Send-WebTestFrame -Socket $ends.Peer -Bytes ($script:Utf8.GetBytes($large))).Wait(5000) 'the large event'
            Assert-True (Send-WebTestFrame -Socket $ends.Peer -Bytes ($script:Utf8.GetBytes('{"id":9,"result":{}}'))).Wait(5000) 'the reply'
            Assert-StringEqual -Expected '{"id":9,"result":{}}' -Actual (Read-WebTestTransport -Transport $ends.Transport)
        } finally { Close-WebTestSocketEnd $ends }
    }

    It 'reports a close frame and a vanished peer as transport' {
        $ends = New-WebTestSocketEnd
        try {
            Assert-True $ends.Peer.CloseOutputAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'bye', [System.Threading.CancellationToken]::None).Wait(5000) 'the peer sent a close frame'
            $failure = Get-WebTestFailure { Read-WebTestTransport -Transport $ends.Transport }
            Assert-StringEqual -Expected 'transport' -Actual $failure.Kind
            Assert-StringEqual -Expected 'close frame' -Actual $failure.Detail
            $later = Get-WebTestFailure { Read-WebTestTransport -Transport $ends.Transport }
            Assert-StringEqual -Expected 'transport' -Actual $later.Kind
            Assert-StringEqual -Expected 'socket closed' -Actual $later.Detail
        } finally { Close-WebTestSocketEnd $ends }
        $ends = New-WebTestSocketEnd
        try {
            Assert-Null (Read-WebTestTransport -Transport $ends.Transport -Milliseconds 20) 'a receive is pending'
            $ends.Peer.Dispose()
            $ends.Pair.Server.Dispose()
            $failure = Get-WebTestFailure { Read-WebTestTransport -Transport $ends.Transport }
            Assert-StringEqual -Expected 'transport' -Actual $failure.Kind
            Assert-True $ends.Transport.Closed 'the transport counts as closed'
            $later = Get-WebTestFailure { Read-WebTestTransport -Transport $ends.Transport }
            Assert-StringEqual -Expected 'transport' -Actual $later.Kind
            Assert-StringEqual -Expected 'socket closed' -Actual $later.Detail
        } finally { Close-WebTestSocketEnd $ends }
    }

    It 'fails a send on a closed socket as transport' {
        $ends = New-WebTestSocketEnd
        try {
            $ends.Transport.Closed = $true
            $failure = Get-WebTestFailure { Invoke-WebTestPrivate -Name 'Write-WebCdpTransport' -Arguments @{ Transport = $ends.Transport; Text = '{"id":1,"method":"Test.x"}'; TimeoutMs = 1000 } }
            Assert-StringEqual -Expected 'transport' -Actual $failure.Kind
            Assert-StringEqual -Expected 'socket closed' -Actual $failure.Detail
        } finally { Close-WebTestSocketEnd $ends }
    }
}

Describe 'commands and replies' {
    BeforeAll {
        function Get-WebTestDeadline {
            param([hashtable]$Clock, [int]$Milliseconds = 30000)
            return ([datetime]$Clock.Now).AddMilliseconds($Milliseconds)
        }
    }

    It 'matches a reply to its request while events arrive between them' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Test.cmd' = {
                    param($Message)
                    @{ method = 'Test.event'; params = @{ n = 1 } }
                    @{ method = 'Test.event'; params = @{ n = 2 } }
                    New-WebTestReply -Message $Message -Result @{ value = 42 }
                }
            })
        $result = Invoke-WebCdp -Connection $t.Connection -Method 'Test.cmd' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        Assert-Equal -Expected 42 -Actual $result['value']
        $queued = @($t.Connection.Events.ToArray())
        Assert-Equal -Expected 2 -Actual $queued.Count
        Assert-True ([long]$queued[1]['Seq'] -gt [long]$queued[0]['Seq']) 'the events are numbered in order'
    }

    It 'ignores a reply with another id and keeps waiting' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Test.cmd' = {
                    param($Message)
                    [ordered]@{ id = 999; result = @{ value = 'stray' } }
                    New-WebTestReply -Message $Message -Result @{ value = 'own' } -AfterMs 100
                }
            })
        $result = Invoke-WebCdp -Connection $t.Connection -Method 'Test.cmd' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        Assert-StringEqual -Expected 'own' -Actual $result['value']
    }

    It 'gives up at the reply limit, abandons the id and drops the late reply' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Test.late' = { param($Message) New-WebTestReply -Message $Message -Result @{ value = 'late' } -AfterMs 15000 }
                'Test.next' = { param($Message) New-WebTestReply -Message $Message -Result @{ value = 'next' } -AfterMs 6000 }
            })
        $start = [datetime]$t.Clock.Now
        $failure = Get-WebTestFailure { Invoke-WebCdp -Connection $t.Connection -Method 'Test.late' -DeadlineUtc (Get-WebTestDeadline $t.Clock 60000) }
        Assert-StringEqual -Expected 'page_lost' -Actual $failure.Kind
        Assert-True $failure.Retryable 'nothing was changed, so the step may try again'
        Assert-StringEqual -Expected 'no reply to Test.late' -Actual $failure.Detail
        Assert-False $failure.DeadlineCut 'the reply limit came before the deadline'
        Assert-Equal -Expected 10000 -Actual ([datetime]$t.Clock.Now - $start).TotalMilliseconds
        $result = Invoke-WebCdp -Connection $t.Connection -Method 'Test.next' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        Assert-StringEqual -Expected 'next' -Actual $result['value']
        Assert-Equal -Expected 0 -Actual $t.Connection.Abandoned.Count -Because 'the late reply was dropped as abandoned'
    }

    It 'never waits past the deadline' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{ 'Test.silent' = { param($Message) $null = $Message } })
        $start = [datetime]$t.Clock.Now
        $failure = Get-WebTestFailure { Invoke-WebCdp -Connection $t.Connection -Method 'Test.silent' -DeadlineUtc $start.AddMilliseconds(300) }
        Assert-StringEqual -Expected 'page_lost' -Actual $failure.Kind
        Assert-True $failure.DeadlineCut 'the step deadline came first'
        Assert-Equal -Expected 300 -Actual ([datetime]$t.Clock.Now - $start).TotalMilliseconds
    }

    It 'reaches a deadline less than a millisecond ahead instead of reading for ever' {
        # A read slice computed as Min(int, double) rounds a remaining time
        # under half a millisecond to 0, and a read of 0 ms never moves the
        # clock. The guard turns such an endless loop into a failure.
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{ 'Test.silent' = { param($Message) $null = $Message } })
        $reads = [ref]0
        $inner = $t.Transport.Receive
        $t.Transport.Receive = {
            param([int]$TimeoutMs)
            $reads.Value++
            if ($reads.Value -gt 1000) { throw 'the reply wait read 1000 times without reaching its deadline' }
            & $inner $TimeoutMs
        }.GetNewClosure()
        $start = [datetime]$t.Clock.Now
        $failure = Get-WebTestFailure { Invoke-WebCdp -Connection $t.Connection -Method 'Test.silent' -DeadlineUtc $start.AddTicks(3000) }
        Assert-StringEqual -Expected 'page_lost' -Actual $failure.Kind
        Assert-True ($reads.Value -le 2) "the wait read $($reads.Value) times"
    }

    It 'sends sessionId and params only when given' {
        $t = New-WebTestConnection -Responder (New-WebTestPage)
        $null = Invoke-WebCdp -Connection $t.Connection -Method 'Test.bare' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        $null = Invoke-WebCdp -Connection $t.Connection -Method 'Test.full' -Params @{ x = 1 } -SessionId 'S1' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        $sent = $t.Transport.State.Sent
        Assert-Equal -Expected 2 -Actual $sent.Count
        Assert-False $sent[0].Contains('params') 'a command without parameters sends none'
        Assert-False $sent[0].Contains('sessionId') 'a browser command names no session'
        Assert-Equal -Expected 1 -Actual $sent[1]['params']['x']
        Assert-StringEqual -Expected 'S1' -Actual $sent[1]['sessionId']
    }

    It 'maps error code <Code> to <Outcome>' -ForEach @(
        @{ Code = -32000; Outcome = 'a retryable page_lost'; OnChild = $false; Allowed = $false; Kind = 'page_lost'; Retryable = $true }
        @{ Code = -32601; Outcome = 'protocol'; OnChild = $false; Allowed = $false; Kind = 'protocol'; Retryable = $false }
        @{ Code = -32602; Outcome = 'protocol for a bad parameter'; OnChild = $false; Allowed = $false; Kind = 'protocol'; Retryable = $false }
        @{ Code = -32001; Outcome = 'page_lost and Gone on the page session'; OnChild = $false; Allowed = $false; Kind = 'page_lost'; Retryable = $false }
        @{ Code = -32001; Outcome = 'a removed child on a child session'; OnChild = $true; Allowed = $false; Kind = 'page_lost'; Retryable = $true }
        @{ Code = -32099; Outcome = 'unsupported'; OnChild = $false; Allowed = $false; Kind = 'unsupported'; Retryable = $false }
        @{ Code = -32602; Outcome = 'ErrorCode when it is allowed'; OnChild = $false; Allowed = $true; Kind = ''; Retryable = $false }
    ) {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Test.cmd' = { param($Message) New-WebTestError -Message $Message -Code $Code -Text 'fixture refusal' }
            })
        $t.Connection.Page.Children['F9'] = @{ SessionId = 'C9'; ParentSessionId = 'S1'; AutoAttach = $true }
        $session = if ($OnChild) { 'C9' } else { 'S1' }
        $arguments = @{ Connection = $t.Connection; Method = 'Test.cmd'; SessionId = $session; DeadlineUtc = (Get-WebTestDeadline $t.Clock) }
        if ($Allowed) {
            $answer = Invoke-WebCdp @arguments -AllowError $Code
            Assert-Equal -Expected $Code -Actual $answer.ErrorCode
            Assert-StringEqual -Expected 'fixture refusal' -Actual $answer.ErrorMessage
            return
        }
        $failure = Get-WebTestFailure { Invoke-WebCdp @arguments }
        Assert-StringEqual -Expected $Kind -Actual $failure.Kind
        Assert-Equal -Expected $Retryable -Actual $failure.Retryable
        if ($Code -eq -32001 -and -not $OnChild) { Assert-StringEqual -Expected 'session closed' -Actual $t.Connection.Page.Gone }
        if ($OnChild) {
            Assert-False $t.Connection.Page.Children.ContainsKey('F9') 'the closed child session is removed'
            Assert-StringEqual -Expected '' -Actual $t.Connection.Page.Gone
        }
    }

    It 'keeps the last 500 events, counts the rest and still applies them' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{ 'Test.cmd' = { param($Message) New-WebTestReply -Message $Message -Result @{ value = 'own' } } })
        Add-WebTestEvent -Transport $t.Transport -Event ([ordered]@{ method = 'Page.frameStartedLoading'; params = @{ frameId = 'T1' }; sessionId = 'S1' })
        foreach ($n in 2..600) { Add-WebTestEvent -Transport $t.Transport -Event ([ordered]@{ method = 'Test.event'; params = @{ n = $n } }) }
        $result = Invoke-WebCdp -Connection $t.Connection -Method 'Test.cmd' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        Assert-StringEqual -Expected 'own' -Actual $result['value']
        Assert-Equal -Expected 500 -Actual $t.Connection.Events.Count
        Assert-Equal -Expected 100 -Actual $t.Connection.DroppedEvents
        Assert-True $t.Connection.Page.Loading 'a dropped event was still applied to the page'
    }

    It 'drains every waiting message before a page operation' {
        $t = New-WebTestConnection -Responder (New-WebTestPage)
        [void]$t.Connection.Abandoned.Add(77)
        foreach ($n in 1..5) { Add-WebTestEvent -Transport $t.Transport -Event ([ordered]@{ method = 'Test.event'; params = @{ n = $n } }) }
        Add-WebTestEvent -Transport $t.Transport -Event ([ordered]@{ id = 77; result = @{} })
        foreach ($n in 6..10) { Add-WebTestEvent -Transport $t.Transport -Event ([ordered]@{ method = 'Test.event'; params = @{ n = $n } }) }
        $before = [long]$t.Connection.EventSeq
        $clockBefore = [datetime]$t.Clock.Now
        Invoke-WebTestPrivate -Name 'Sync-WebCdpEvent' -Arguments @{ Connection = $t.Connection }
        Assert-Equal -Expected 10 -Actual ([long]$t.Connection.EventSeq - $before)
        Assert-Equal -Expected 0 -Actual $t.Connection.Abandoned.Count
        Assert-Equal -Expected $clockBefore -Actual ([datetime]$t.Clock.Now)
        Assert-Equal -Expected 0 -Actual $t.Transport.State.Inbound.Count
    }

    It 'keeps a name that looks like a date as text' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{ 'Test.cmd' = { param($Message) New-WebTestReply -Message $Message -Result @{ value = '2026-11-17T10:00:00Z' } } })
        $result = Invoke-WebCdp -Connection $t.Connection -Method 'Test.cmd' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        Assert-True ($result['value'] -is [string]) "the value became $($result['value'].GetType().FullName)"
        Assert-True ([string]::Equals('2026-11-17T10:00:00Z', $result['value'], [StringComparison]::Ordinal)) "read $($result['value'])"
    }

    It '<Event> <Does>' -ForEach @(
        @{ Event = 'Page.frameStartedLoading'; Does = 'marks the main frame loading'; SessionId = 'S1'; Params = @{ frameId = 'T1' }
            Arrange = $null; Check = { param($page, $seq) Assert-True $page.Loading; Assert-Equal $seq $page.NavigationSeq } }
        @{ Event = 'Page.frameStoppedLoading'; Does = 'marks the main frame loaded'; SessionId = 'S1'; Params = @{ frameId = 'T1' }
            Arrange = { param($page) $page.Loading = $true }; Check = { param($page, $seq) Assert-False $page.Loading; Assert-Equal $seq $page.NavigationSeq } }
        @{ Event = 'Page.frameNavigated'; Does = 'records the commit of the main frame'; SessionId = 'S1'; Params = @{ frame = @{ id = 'T1'; url = 'chrome-error://chromewebdata/'; unreachableUrl = 'http://127.0.0.1:9/' } }
            Arrange = { param($page) $page.Crashed = $true }
            Check = {
                param($page, $seq)
                Assert-StringEqual 'chrome-error://chromewebdata/' $page.Url
                Assert-StringEqual 'http://127.0.0.1:9/' $page.UnreachableUrl
                Assert-Equal $seq $page.CommitSeq
                Assert-Equal 1 $page.Generation
                Assert-False $page.Crashed
                Assert-Equal $seq $page.NavigationSeq
            } }
        @{ Event = 'Page.navigatedWithinDocument'; Does = 'takes the new URL of the main frame'; SessionId = 'S1'; Params = @{ frameId = 'T1'; url = 'http://localhost/a#b' }
            Arrange = $null; Check = { param($page, $seq) Assert-StringEqual 'http://localhost/a#b' $page.Url; Assert-Equal $seq $page.NavigationSeq; Assert-Equal 0 $page.Generation } }
        @{ Event = 'Page.frameRequestedNavigation'; Does = 'touches the navigation time'; SessionId = 'S1'; Params = @{ frameId = 'T1' }
            Arrange = $null; Check = { param($page, $seq) Assert-Equal $seq $page.NavigationSeq; Assert-NotEqual ([datetime]::MinValue) $page.NavigationUtc } }
        @{ Event = 'Page.frameScheduledNavigation'; Does = 'touches the navigation time'; SessionId = 'S1'; Params = @{ frameId = 'T1' }
            Arrange = $null; Check = { param($page, $seq) Assert-Equal $seq $page.NavigationSeq } }
        @{ Event = 'Page.frameStartedNavigating'; Does = 'touches the navigation time'; SessionId = 'S1'; Params = @{ frameId = 'T1' }
            Arrange = $null; Check = { param($page, $seq) Assert-Equal $seq $page.NavigationSeq } }
        @{ Event = 'Page.frameClearedScheduledNavigation'; Does = 'touches the navigation time'; SessionId = 'S1'; Params = @{ frameId = 'T1' }
            Arrange = $null; Check = { param($page, $seq) Assert-Equal $seq $page.NavigationSeq } }
        @{ Event = 'Page.javascriptDialogOpening'; Does = 'records the dialog with its text cut at 200'; SessionId = 'S1'; Params = @{ type = 'confirm'; message = ('m' * 250) }
            Arrange = $null; Check = { param($page, $seq) Assert-StringEqual 'confirm' $page.Dialog.Type; Assert-Equal 200 $page.Dialog.Message.Length; Assert-Equal $seq $page.Dialog.Seq } }
        @{ Event = 'Page.javascriptDialogClosed'; Does = 'clears the dialog'; SessionId = 'S1'; Params = @{ result = $true }
            Arrange = { param($page) $page.Dialog = @{ Type = 'alert'; Message = 'x'; Seq = 1 } }; Check = { param($page) Assert-Null $page.Dialog } }
        @{ Event = 'Inspector.targetCrashed'; Does = 'marks the page crashed'; SessionId = 'S1'; Params = @{}
            Arrange = $null; Check = { param($page) Assert-True $page.Crashed } }
        @{ Event = 'Inspector.targetReloadedAfterCrash'; Does = 'clears the crash'; SessionId = 'S1'; Params = @{}
            Arrange = { param($page) $page.Crashed = $true }; Check = { param($page) Assert-False $page.Crashed } }
        @{ Event = 'Inspector.detached'; Does = 'marks the page gone with the reason'; SessionId = 'S1'; Params = @{ reason = 'target_closed' }
            Arrange = $null; Check = { param($page) Assert-StringEqual 'detached: target_closed' $page.Gone } }
        @{ Event = 'Target.targetCrashed'; Does = 'marks the owned target crashed'; SessionId = ''; Params = @{ targetId = 'T1'; status = 'crashed'; errorCode = 1 }
            Arrange = $null; Check = { param($page) Assert-True $page.Crashed } }
        @{ Event = 'Target.targetDestroyed'; Does = 'marks the owned target gone'; SessionId = ''; Params = @{ targetId = 'T1' }
            Arrange = $null; Check = { param($page) Assert-StringEqual 'target closed' $page.Gone } }
        @{ Event = 'Target.targetDestroyed'; Does = 'removes a destroyed popup'; SessionId = ''; Params = @{ targetId = 'P1' }
            Arrange = { param($page) $page.Popups.Add(@{ TargetId = 'P1'; Url = 'about:blank'; Seq = 0L }) }
            Check = { param($page) Assert-Equal 0 $page.Popups.Count; Assert-StringEqual '' $page.Gone } }
        @{ Event = 'Target.targetCreated'; Does = 'adds a window the page opened to its popups'; SessionId = ''; Params = @{ targetInfo = @{ targetId = 'P2'; type = 'page'; url = 'http://localhost/pop'; openerId = 'T1' } }
            Arrange = $null; Check = { param($page, $seq) Assert-Equal 1 $page.Popups.Count; Assert-StringEqual 'P2' $page.Popups[0].TargetId; Assert-StringEqual 'http://localhost/pop' $page.Popups[0].Url; Assert-Equal $seq $page.Popups[0].Seq } }
        @{ Event = 'Target.attachedToTarget'; Does = 'records a child session of a cross-site frame'; SessionId = 'S1'; Params = @{ sessionId = 'C1'; targetInfo = @{ targetId = 'F1'; type = 'iframe' }; waitingForDebugger = $false }
            Arrange = $null
            Check = { param($page) Assert-StringEqual 'C1' $page.Children['F1'].SessionId; Assert-StringEqual 'S1' $page.Children['F1'].ParentSessionId; Assert-False $page.Children['F1'].AutoAttach } }
        @{ Event = 'Target.detachedFromTarget'; Does = 'marks the page gone when its own session detaches'; SessionId = ''; Params = @{ sessionId = 'S1' }
            Arrange = $null; Check = { param($page) Assert-StringEqual 'session detached' $page.Gone } }
        @{ Event = 'Target.detachedFromTarget'; Does = 'removes the child whose session detached'; SessionId = 'S1'; Params = @{ sessionId = 'C1' }
            Arrange = { param($page) $page.Children['F1'] = @{ SessionId = 'C1'; ParentSessionId = 'S1'; AutoAttach = $true } }
            Check = { param($page) Assert-False $page.Children.ContainsKey('F1'); Assert-StringEqual '' $page.Gone } }
        @{ Event = 'Browser.downloadWillBegin'; Does = 'records a download'; SessionId = ''; Params = @{ frameId = 'T1'; guid = 'g'; url = 'http://localhost/f.bin'; suggestedFilename = 'f.bin' }
            Arrange = $null; Check = { param($page, $seq) Assert-Equal $seq $page.DownloadSeq } }
        @{ Event = 'Page.frameStartedLoading'; Does = 'leaves the page alone for a sub-frame'; SessionId = 'S1'; Params = @{ frameId = 'SUB' }
            Arrange = $null; Check = { param($page) Assert-False $page.Loading; Assert-Equal 0 $page.NavigationSeq } }
        @{ Event = 'Target.targetCreated'; Does = 'leaves the popups alone for a target without opener'; SessionId = ''; Params = @{ targetInfo = @{ targetId = 'OLD'; type = 'page'; url = 'about:blank' } }
            Arrange = $null; Check = { param($page) Assert-Equal 0 $page.Popups.Count } }
        @{ Event = 'Page.frameStartedLoading'; Does = 'leaves the page alone for the main frame id on another session'; SessionId = 'C7'; Params = @{ frameId = 'T1' }
            Arrange = $null; Check = { param($page) Assert-False $page.Loading; Assert-Equal 0 $page.NavigationSeq } }
    ) {
        $t = New-WebTestConnection -Responder (New-WebTestPage)
        $page = $t.Connection.Page
        if ($Arrange) { & $Arrange $page }
        $message = [ordered]@{ method = $Event; params = $Params }
        if ($SessionId) { $message['sessionId'] = $SessionId }
        Add-WebTestEvent -Transport $t.Transport -Event $message
        Invoke-WebTestPrivate -Name 'Sync-WebCdpEvent' -Arguments @{ Connection = $t.Connection }
        Assert-Equal -Expected 1 -Actual $t.Connection.EventSeq -Because 'the event was read'
        & $Check $page ([long]$t.Connection.EventSeq)
    }

    It 'dismisses a dialog that opens while it waits and fails as unsupported' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Test.cmd' = { param($Message) $null = $Message; [ordered]@{ method = 'Page.javascriptDialogOpening'; params = @{ type = 'alert'; message = 'hi' }; sessionId = 'S1' } }
                'Test.next' = { param($Message) New-WebTestReply -Message $Message -Result @{ value = 'next' } }
            })
        $failure = Get-WebTestFailure { Invoke-WebCdp -Connection $t.Connection -Method 'Test.cmd' -SessionId 'S1' -DeadlineUtc (Get-WebTestDeadline $t.Clock) }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'dialog: alert' -Actual $failure.Detail
        $handled = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Page.handleJavaScriptDialog' })
        Assert-Equal -Expected 1 -Actual $handled.Count
        Assert-Equal -Expected $false -Actual $handled[0]['params']['accept']
        $next = Invoke-WebCdp -Connection $t.Connection -Method 'Test.next' -SessionId 'S1' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        Assert-StringEqual -Expected 'next' -Actual $next['value']
    }

    It 'accepts a leave-page prompt when asked to and goes on waiting' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Test.leave' = {
                    param($Message)
                    [ordered]@{ method = 'Page.javascriptDialogOpening'; params = @{ type = 'beforeunload'; message = '' }; sessionId = 'S1' }
                    New-WebTestReply -Message $Message -Result @{ value = 'left' } -AfterMs 100
                }
            })
        $result = Invoke-WebCdp -Connection $t.Connection -Method 'Test.leave' -SessionId 'S1' -AcceptBeforeUnload -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        Assert-StringEqual -Expected 'left' -Actual $result['value']
        $handled = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Page.handleJavaScriptDialog' })
        Assert-Equal -Expected 1 -Actual $handled.Count
        Assert-Equal -Expected $true -Actual $handled[0]['params']['accept']
    }

    It 'counts a dialog that closed by itself as handled' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Test.cmd' = { param($Message) $null = $Message; [ordered]@{ method = 'Page.javascriptDialogOpening'; params = @{ type = 'alert'; message = 'hi' }; sessionId = 'S1' } }
                'Page.handleJavaScriptDialog' = { param($Message) New-WebTestError -Message $Message -Code -32602 -Text 'No dialog is showing' }
                'Test.next' = { param($Message) New-WebTestReply -Message $Message -Result @{ value = 'next' } }
            })
        $failure = Get-WebTestFailure { Invoke-WebCdp -Connection $t.Connection -Method 'Test.cmd' -SessionId 'S1' -DeadlineUtc (Get-WebTestDeadline $t.Clock) }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'dialog: alert' -Actual $failure.Detail
        Assert-StringEqual -Expected '' -Actual $t.Connection.Page.Gone
        $next = Invoke-WebCdp -Connection $t.Connection -Method 'Test.next' -SessionId 'S1' -DeadlineUtc (Get-WebTestDeadline $t.Clock)
        Assert-StringEqual -Expected 'next' -Actual $next['value']
    }

    It 'dismisses a leave-page prompt that opens outside an open and fails as unsupported' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Test.cmd' = { param($Message) $null = $Message; [ordered]@{ method = 'Page.javascriptDialogOpening'; params = @{ type = 'beforeunload'; message = '' }; sessionId = 'S1' } }
            })
        $failure = Get-WebTestFailure { Invoke-WebCdp -Connection $t.Connection -Method 'Test.cmd' -SessionId 'S1' -DeadlineUtc (Get-WebTestDeadline $t.Clock) }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'dialog: beforeunload' -Actual $failure.Detail
        $handled = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Page.handleJavaScriptDialog' })
        Assert-Equal -Expected 1 -Actual $handled.Count
        Assert-Equal -Expected $false -Actual $handled[0]['params']['accept']
    }
}

Describe 'the owned page' {
    BeforeAll {
        # A connection whose page is not opened yet, so a case sees the setup
        # commands, or queues an event before them.
        function New-WebTestBareConnection {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory connection over a scripted transport.')]
            param([Parameter(Mandatory)][scriptblock]$Responder)
            $clock = New-WebTestClock
            $transport = New-WebTestTransport -Responder $Responder -Clock $clock
            $connection = Invoke-WebTestPrivate -Name 'New-WebCdpConnection' -Arguments @{ Transport = $transport; Clock = $clock }
            return @{ Connection = $connection; Transport = $transport; Clock = $clock }
        }
    }

    It 'creates one page, attaches flat, enables only the Page domain and keeps the main frame id' {
        $t = New-WebTestBareConnection -Responder (New-WebTestPage)
        Open-WebCdpPage -Connection $t.Connection -DeadlineUtc ([datetime]$t.Clock.Now).AddSeconds(30)
        $sent = @($t.Transport.State.Sent)
        $methods = @($sent | ForEach-Object { [string]$_['method'] })
        $expected = @('Target.createTarget', 'Target.attachToTarget', 'Page.enable', 'Page.getFrameTree', 'Target.setAutoAttach',
            'Emulation.setFocusEmulationEnabled', 'Emulation.setDeviceMetricsOverride')
        Assert-True ([string]::Equals(($expected -join ','), ($methods -join ','), [StringComparison]::Ordinal)) "sent $($methods -join ',')"
        Assert-Equal -Expected $true -Actual $sent[1]['params']['flatten']
        Assert-StringEqual -Expected 'T1' -Actual $sent[1]['params']['targetId']
        foreach ($message in $sent[2..6]) { Assert-StringEqual -Expected 'S1' -Actual $message['sessionId'] -Because $message['method'] }
        foreach ($message in $sent[0..1]) { Assert-False $message.Contains('sessionId') $message['method'] }
        Assert-False ($methods -contains 'DOM.enable') 'the DOM domain stays off'
        Assert-False ($methods -contains 'Accessibility.enable') 'the accessibility domain stays off'
        Assert-StringEqual -Expected 'T1' -Actual $t.Connection.Page.MainFrameId
        Assert-True (Test-WebCdpOpen -Connection $t.Connection) 'the page is open'
    }

    It 'closes its popups and its page, then the transport, and may be closed twice' {
        $t = New-WebTestConnection -Responder (New-WebTestPage)
        $t.Connection.Page.Popups.Add(@{ TargetId = 'P1'; Url = 'about:blank'; Seq = 1L })
        Close-WebCdp -Connection $t.Connection
        $closes = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Target.closeTarget' } | ForEach-Object { [string]$_['params']['targetId'] })
        Assert-True ([string]::Equals('P1,T1', ($closes -join ','), [StringComparison]::Ordinal)) "closed $($closes -join ',')"
        Assert-True $t.Transport.Closed 'the transport is closed'
        Assert-True $t.Transport.State.Closed 'the scripted close ran'
        Assert-False (Test-WebCdpOpen -Connection $t.Connection) 'the connection is closed'
        $count = $t.Transport.State.Sent.Count
        Close-WebCdp -Connection $t.Connection
        Assert-Equal -Expected $count -Actual $t.Transport.State.Sent.Count -Because 'a second close sends nothing'
    }

    It 'closes the target it created when a later setup command fails' {
        $t = New-WebTestBareConnection -Responder (New-WebTestPage -Override @{ 'Page.enable' = { param($Message) New-WebTestError -Message $Message -Code -32601 -Text "'Page.enable' wasn't found" } })
        $failure = Get-WebTestFailure { Open-WebCdpPage -Connection $t.Connection -DeadlineUtc ([datetime]$t.Clock.Now).AddSeconds(30) }
        Assert-StringEqual -Expected 'protocol' -Actual $failure.Kind
        $closes = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Target.closeTarget' })
        Assert-Equal -Expected 1 -Actual $closes.Count
        Assert-StringEqual -Expected 'T1' -Actual $closes[0]['params']['targetId']
        Assert-True $t.Transport.Closed 'the transport is closed'
        Assert-False (Test-WebCdpOpen -Connection $t.Connection) 'no half-opened page stays open'
    }

    It 'attaches to no target it did not create' {
        $root = New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Page' -Children '2' -Backend 1
        $button = New-WebTestAxNode -Id '2' -Role 'button' -Name 'Go' -Backend 5
        $t = New-WebTestBareConnection -Responder (New-WebTestPage -Ax @{ 'S1' = @($root, $button) } -Quads @{ 5 = @(10, 10, 30, 10, 30, 30, 10, 30) })
        Add-WebTestEvent -Transport $t.Transport -Event ([ordered]@{ method = 'Target.targetCreated'; params = @{ targetInfo = @{ targetId = 'OLD'; type = 'page'; url = 'about:blank' } } })
        Open-WebCdpPage -Connection $t.Connection -DeadlineUtc ([datetime]$t.Clock.Now).AddSeconds(30)
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $null = Invoke-WebPageClick -Connection $t.Connection -Locator ([ordered]@{ role = 'button'; name = 'Go' }) -DeadlineUtc ([datetime]$t.Clock.Now).AddSeconds(30) -Effect $effect
        Assert-True $effect.Acknowledged 'the click went through'
        foreach ($message in $t.Transport.State.Sent) {
            $text = ConvertTo-Json -InputObject $message -Depth 16 -Compress
            Assert-False ($text.Contains('"OLD"')) "a command names the foreign target: $text"
            if ($message.Contains('sessionId')) { Assert-True ([string]::Equals('S1', [string]$message['sessionId'], [StringComparison]::Ordinal)) "a command names another session: $text" }
        }
    }

    It 'closes every popup and its page when the browser reports each target destroyed before it answers the close' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Target.closeTarget' = {
                    param($Message)
                    [ordered]@{ method = 'Target.targetDestroyed'; params = @{ targetId = [string]$Message['params']['targetId'] } }
                    New-WebTestReply -Message $Message -Result @{ success = $true } -AfterMs 10
                }
            })
        $t.Connection.Page.Popups.Add(@{ TargetId = 'P1'; Url = 'about:blank'; Seq = 1L })
        $t.Connection.Page.Popups.Add(@{ TargetId = 'P2'; Url = 'about:blank'; Seq = 2L })
        Close-WebCdp -Connection $t.Connection
        $closes = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Target.closeTarget' } | ForEach-Object { [string]$_['params']['targetId'] })
        Assert-True ([string]::Equals('P1,P2,T1', ($closes -join ','), [StringComparison]::Ordinal)) "closed $($closes -join ',')"
        Assert-True $t.Transport.Closed 'the transport is closed'
    }
}

Describe 'the page forest' {
    BeforeAll {
        function Read-WebTestForest {
            param([hashtable]$T, [int]$Milliseconds = 30000)
            Read-WebPageForest -Connection $T.Connection -DeadlineUtc ([datetime]$T.Clock.Now).AddMilliseconds($Milliseconds)
        }

        function Get-WebTestAxRead {
            param([hashtable]$T)
            return @($T.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Accessibility.getFullAXTree' })
        }
    }

    It 'walks child ids in document order, not array order' {
        $nodes = @(
            (New-WebTestAxNode -Id '4' -Role 'link' -Name 'Third' -Backend 14)
            (New-WebTestAxNode -Id '5' -Role 'StaticText' -Name 'inner' -Backend 15)
            (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Order' -Children '2', '3', '4' -Backend 11)
            (New-WebTestAxNode -Id '3' -Role 'button' -Name 'Second' -Children '5' -Backend 13)
            (New-WebTestAxNode -Id '2' -Role 'heading' -Name 'First' -Backend 12)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ 'S1' = $nodes })
        $forest = Read-WebTestForest $t
        $order = @($forest.Entries | ForEach-Object { [string]$_.Name })
        Assert-True ([string]::Equals('Order,First,Second,inner,Third', ($order -join ','), [StringComparison]::Ordinal)) "entries $($order -join ',')"
        Assert-Equal -Expected 2 -Actual ($forest.Entries | Where-Object { $_.Name -eq 'inner' }).Depth
        Assert-StringEqual -Expected 'Order' -Actual $forest.Title
    }

    It 'passes over ignored nodes and inline text boxes and keeps what is below an ignored node' {
        $nodes = @(
            (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Page' -Children '2', '4', '6' -Backend 1)
            (New-WebTestAxNode -Id '2' -Role 'generic' -Children '3' -Backend 2 -Ignored)
            (New-WebTestAxNode -Id '3' -Role 'button' -Name 'Kept' -Backend 3)
            (New-WebTestAxNode -Id '4' -Role 'StaticText' -Name 'Words' -Children '5' -Backend 4)
            (New-WebTestAxNode -Id '5' -Role 'InlineTextBox' -Name 'Words')
            (New-WebTestAxNode -Id '6' -Role 'InlineTextBox' -Name 'Loose')
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ 'S1' = $nodes })
        $forest = Read-WebTestForest $t
        $roles = @($forest.Entries | ForEach-Object { "$($_.Role):$($_.Name):$($_.Depth)" })
        Assert-True ([string]::Equals('RootWebArea:Page:0,button:Kept:1,StaticText:Words:1', ($roles -join ','), [StringComparison]::Ordinal)) "entries $($roles -join ',')"
        Assert-StringEqual -Expected 'Words' -Actual $forest.Text
    }

    It 'reads a same-process frame by frame id and an attached frame on its own session' {
        $page = @(
            (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Outer' -Children '2', '3' -Backend 1)
            (New-WebTestAxNode -Id '2' -Role 'Iframe' -Backend 10)
            (New-WebTestAxNode -Id '3' -Role 'Iframe' -Backend 20)
        )
        $sameProcess = @(
            (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Same' -Children '2' -Backend 101)
            (New-WebTestAxNode -Id '2' -Role 'button' -Name 'Near' -Backend 102)
        )
        $child = @(
            (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Far' -Children '2' -Backend 201)
            (New-WebTestAxNode -Id '2' -Role 'button' -Name 'Away' -Backend 202)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ 'S1' = $page; 'S1|F1' = $sameProcess; 'C2' = $child } -Describe @{
                10 = @{ backendNodeId = 10; nodeName = 'IFRAME'; frameId = 'F1' }
                20 = @{ backendNodeId = 20; nodeName = 'IFRAME'; frameId = 'F2' }
            })
        $t.Connection.Page.Children['F2'] = @{ SessionId = 'C2'; ParentSessionId = 'S1'; AutoAttach = $true }
        $forest = Read-WebTestForest $t
        $reads = Get-WebTestAxRead $t
        $frameReads = @($reads | Where-Object { $_['params'].Contains('frameId') })
        Assert-Equal -Expected 1 -Actual $frameReads.Count
        Assert-StringEqual -Expected 'F1' -Actual $frameReads[0]['params']['frameId']
        Assert-StringEqual -Expected 'S1' -Actual $frameReads[0]['sessionId']
        $childReads = @($reads | Where-Object { $_['sessionId'] -ceq 'C2' })
        Assert-Equal -Expected 1 -Actual $childReads.Count
        Assert-False $childReads[0]['params'].Contains('frameId') 'the child session reads its own main frame'
        $near = $forest.Entries | Where-Object { $_.Name -eq 'Near' }
        Assert-StringEqual -Expected 'S1' -Actual $near.Address.SessionId
        Assert-Equal -Expected 0 -Actual @($near.Address.Owners).Count
        $away = $forest.Entries | Where-Object { $_.Name -eq 'Away' }
        Assert-StringEqual -Expected 'C2' -Actual $away.Address.SessionId
        Assert-Equal -Expected 1 -Actual @($away.Address.Owners).Count
        Assert-StringEqual -Expected 'S1' -Actual $away.Address.Owners[0].SessionId
        Assert-Equal -Expected 20 -Actual $away.Address.Owners[0].BackendNodeId
        $order = @($forest.Entries | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
        Assert-True ([string]::Equals('Outer,Same,Near,Far,Away', ($order -join ','), [StringComparison]::Ordinal)) "entries $($order -join ',')"
    }

    It 'turns on auto-attach once for a new child session' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ 'S1' = @(New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Page' -Backend 1) })
        $t.Connection.Page.Children['F2'] = @{ SessionId = 'C2'; ParentSessionId = 'S1'; AutoAttach = $false }
        $null = Read-WebTestForest $t
        $null = Read-WebTestForest $t
        $attach = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Target.setAutoAttach' -and $_['sessionId'] -ceq 'C2' })
        Assert-Equal -Expected 1 -Actual $attach.Count
        Assert-Equal -Expected $true -Actual $attach[0]['params']['flatten']
        Assert-True $t.Connection.Page.Children['F2'].AutoAttach 'the flag is set'
    }

    It 'marks the forest incomplete when a frame cannot be read or is nested too deep' {
        $page = @(
            (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Outer' -Children '2' -Backend 1)
            (New-WebTestAxNode -Id '2' -Role 'Iframe' -Backend 10)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ 'S1' = $page } -Describe @{ 10 = @{ backendNodeId = 10; nodeName = 'IFRAME'; frameId = 'FX' } })
        $forest = Read-WebTestForest $t
        Assert-True $forest.Incomplete 'a frame that answers -32602 leaves the forest incomplete'

        $ax = @{ 'S1' = @(
                (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Level 0' -Children '2' -Backend 1)
                (New-WebTestAxNode -Id '2' -Role 'Iframe' -Backend 101)
            )
        }
        $describe = @{ 101 = @{ backendNodeId = 101; nodeName = 'IFRAME'; frameId = 'L1' } }
        foreach ($level in 1..9) {
            $ax["S1|L$level"] = @(
                (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name "Level $level" -Children '2' -Backend (1000 + $level))
                (New-WebTestAxNode -Id '2' -Role 'Iframe' -Backend (101 + $level))
            )
            $describe[101 + $level] = @{ backendNodeId = 101 + $level; nodeName = 'IFRAME'; frameId = "L$($level + 1)" }
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax $ax -Describe $describe)
        $forest = Read-WebTestForest $t
        Assert-True $forest.Incomplete 'a ninth frame level leaves the forest incomplete'
        $deepest = @(Get-WebTestAxRead $t | Where-Object { $_['params'].Contains('frameId') } | ForEach-Object { [string]$_['params']['frameId'] })
        Assert-True ([string]::Equals('L1,L2,L3,L4,L5,L6,L7,L8', ($deepest -join ','), [StringComparison]::Ordinal)) "read $($deepest -join ',')"
    }

    It 'stops at the entry limit and says so' {
        $nodes = [System.Collections.Generic.List[object]]::new()
        $nodes.Add((New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Long' -Children ([string[]](2..9)) -Backend 1))
        foreach ($n in 2..9) { $nodes.Add((New-WebTestAxNode -Id "$n" -Role 'button' -Name "B$n" -Backend $n)) }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ 'S1' = $nodes.ToArray() })
        # The real limit is 20,000 entries; a page that large would make this
        # case slow, so the limit is lowered for the read and restored.
        $saved = InModuleScope Test.WebSession { $script:WebLimit.MaxForestEntries }
        try {
            InModuleScope Test.WebSession { $script:WebLimit.MaxForestEntries = 5 }
            $forest = Read-WebTestForest $t
        } finally {
            InModuleScope Test.WebSession -Parameters @{ Limit = $saved } { param($Limit) $script:WebLimit.MaxForestEntries = $Limit }
        }
        Assert-True $forest.Truncated 'the read says it stopped early'
        Assert-Equal -Expected 5 -Actual @($forest.Entries).Count
        Assert-Equal -Expected 20000 -Actual (Get-WebLimit).MaxForestEntries
    }

    It 'joins the text of one line and separates blocks' {
        $nodes = @(
            (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Text' -Children '2', '7', '11', '13', '15' -Backend 1)
            (New-WebTestAxNode -Id '2' -Role 'paragraph' -Children '3', '4', '6' -Backend 2)
            (New-WebTestAxNode -Id '3' -Role 'StaticText' -Name 'Wel' -Backend 3)
            (New-WebTestAxNode -Id '4' -Role 'mark' -Children '5' -Backend 4)
            (New-WebTestAxNode -Id '5' -Role 'StaticText' -Name 'come' -Backend 5)
            (New-WebTestAxNode -Id '6' -Role 'StaticText' -Name ' aboard' -Backend 6)
            (New-WebTestAxNode -Id '7' -Role 'paragraph' -Children '8', '10' -Backend 7)
            (New-WebTestAxNode -Id '8' -Role 'strong' -Children '9' -Backend 8)
            (New-WebTestAxNode -Id '9' -Role 'StaticText' -Name 'Error' -Backend 9)
            (New-WebTestAxNode -Id '10' -Role 'StaticText' -Name ': failed' -Backend 10)
            (New-WebTestAxNode -Id '11' -Role 'paragraph' -Children '12' -Backend 11)
            (New-WebTestAxNode -Id '12' -Role 'StaticText' -Name 'Block A' -Backend 12)
            (New-WebTestAxNode -Id '13' -Role 'paragraph' -Children '14' -Backend 13)
            (New-WebTestAxNode -Id '14' -Role 'StaticText' -Name 'Block B' -Backend 14)
            (New-WebTestAxNode -Id '15' -Role 'paragraph' -Children '16', '17', '18' -Backend 15)
            (New-WebTestAxNode -Id '16' -Role 'StaticText' -Name 'Line one' -Backend 16)
            (New-WebTestAxNode -Id '17' -Role 'LineBreak' -Name "`n" -Backend 17)
            (New-WebTestAxNode -Id '18' -Role 'StaticText' -Name 'Line two' -Backend 18)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ 'S1' = $nodes })
        $forest = Read-WebTestForest $t
        Assert-True ([string]::Equals('Welcome aboard Error: failed Block A Block B Line one Line two', $forest.Text, [StringComparison]::Ordinal)) "text '$($forest.Text)'"
    }

    It 'leaves field values out of the page text' {
        $nodes = @(
            (New-WebTestAxNode -Id '1' -Role 'RootWebArea' -Name 'Form' -Children '2', '3' -Backend 1)
            (New-WebTestAxNode -Id '2' -Role 'StaticText' -Name 'Your name' -Backend 2)
            (New-WebTestAxNode -Id '3' -Role 'textbox' -Name 'Your name' -Value 'typed-value' -Children '4' -Backend 3 -Props @{ editable = 'plaintext' })
            (New-WebTestAxNode -Id '4' -Role 'StaticText' -Name 'typed-value' -Backend 4)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ 'S1' = $nodes })
        $forest = Read-WebTestForest $t
        Assert-False ($forest.Text.Contains('typed-value')) "text '$($forest.Text)'"
        Assert-StringEqual -Expected 'Your name' -Actual $forest.Text
        $inner = $forest.Entries | Where-Object { $_.Role -eq 'StaticText' -and $_.Name -eq 'typed-value' }
        Assert-True $inner.InTextControl 'the value text is marked as inside a text control'
        Assert-StringEqual -Expected 'typed-value' -Actual ($forest.Entries | Where-Object { $_.Role -eq 'textbox' }).Value
    }

    It 'dismisses an open dialog, closes a popup, and fails; fails on a crashed page' {
        $t = New-WebTestConnection -Responder (New-WebTestPage)
        Add-WebTestEvent -Transport $t.Transport -Event ([ordered]@{ method = 'Page.javascriptDialogOpening'; params = @{ type = 'alert'; message = 'hi' }; sessionId = 'S1' })
        $failure = Get-WebTestFailure { Read-WebTestForest $t }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'dialog: alert' -Actual $failure.Detail
        Assert-Equal -Expected 1 -Actual @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Page.handleJavaScriptDialog' -and $_['params']['accept'] -eq $false }).Count
        Assert-Null $t.Connection.Page.Dialog 'the dialog was dismissed'

        $t = New-WebTestConnection -Responder (New-WebTestPage)
        $t.Connection.Page.Popups.Add(@{ TargetId = 'P1'; Url = 'about:blank'; Seq = 1L })
        $failure = Get-WebTestFailure { Read-WebTestForest $t }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'popup' -Actual $failure.Detail
        $closes = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Target.closeTarget' })
        Assert-Equal -Expected 1 -Actual $closes.Count
        Assert-StringEqual -Expected 'P1' -Actual $closes[0]['params']['targetId']
        Assert-False $closes[0].Contains('sessionId') 'a window is closed on the browser session'
        Assert-Equal -Expected 0 -Actual $t.Connection.Page.Popups.Count

        $t = New-WebTestConnection -Responder (New-WebTestPage)
        Add-WebTestEvent -Transport $t.Transport -Event ([ordered]@{ method = 'Inspector.targetCrashed'; params = @{}; sessionId = 'S1' })
        $failure = Get-WebTestFailure { Read-WebTestForest $t }
        Assert-StringEqual -Expected 'page_lost' -Actual $failure.Kind
        Assert-StringEqual -Expected 'crashed' -Actual $failure.Detail
    }

    It 'closes a popup that is already gone without a protocol error' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{ 'Target.closeTarget' = { param($Message) New-WebTestError -Message $Message -Code -32602 -Text 'No target with given id found' } })
        $t.Connection.Page.Popups.Add(@{ TargetId = 'P1'; Url = 'about:blank'; Seq = 1L })
        $failure = Get-WebTestFailure { Read-WebTestForest $t }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'popup' -Actual $failure.Detail
        Assert-Equal -Expected 0 -Actual $t.Connection.Page.Popups.Count
    }

    It 'keeps a popup whose close gets no reply and still fails as unsupported' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Override @{
                'Target.closeTarget' = {
                    param($Message)
                    if ([string]$Message['params']['targetId'] -cne 'P1') { New-WebTestReply -Message $Message -Result @{ success = $true } }
                }
            })
        $t.Connection.Page.Popups.Add(@{ TargetId = 'P1'; Url = 'about:blank'; Seq = 1L })
        $t.Connection.Page.Popups.Add(@{ TargetId = 'P2'; Url = 'about:blank'; Seq = 2L })
        $start = [datetime]$t.Clock.Now
        $failure = Get-WebTestFailure { Read-WebTestForest $t }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'popup' -Actual $failure.Detail
        $closes = @($t.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Target.closeTarget' } | ForEach-Object { [string]$_['params']['targetId'] })
        Assert-True ([string]::Equals('P1,P2', ($closes -join ','), [StringComparison]::Ordinal)) "closed $($closes -join ',')"
        Assert-Equal -Expected 1 -Actual $t.Connection.Page.Popups.Count
        Assert-StringEqual -Expected 'P1' -Actual $t.Connection.Page.Popups[0].TargetId
        Assert-Equal -Expected 2000 -Actual ([datetime]$t.Clock.Now - $start).TotalMilliseconds -Because 'the close waited CleanupLimitMs'
    }
}

Describe 'the locator' {
    BeforeAll {
        # A page tree: a root that holds the given top-level nodes, then every node.
        function New-FbTree {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory accessibility tree.')]
            param([object[]]$Nodes = @(), [string[]]$Top)
            $Nodes = @($Nodes | Where-Object { $null -ne $_ })
            if ($null -eq $Top) { $Top = @($Nodes | ForEach-Object { [string]$_['nodeId'] }) }
            $root = New-WebTestAxNode -Id 'root' -Role 'RootWebArea' -Name 'Fixture' -Children $Top
            return , (@($root) + @($Nodes))
        }
        function Get-FbQuad {
            param([double]$X, [double]$Y, [double]$Half = 10)
            return , @(($X - $Half), ($Y - $Half), ($X + $Half), ($Y - $Half), ($X + $Half), ($Y + $Half), ($X - $Half), ($Y + $Half))
        }
        # The page failure an action throws, or $null when it throws nothing.
        function Get-FbFailure {
            param([Parameter(Mandatory)][scriptblock]$Action)
            try {
                $null = & $Action
            } catch {
                $failure = Get-WebFailureData -ErrorRecord $_
                if ($null -eq $failure) { throw }
                return $failure
            }
            return $null
        }
        function Get-FbSent {
            param([Parameter(Mandatory)][hashtable]$Test, [string]$Method)
            return , @($Test.Transport.State.Sent | Where-Object { -not $Method -or [string]$_['method'] -ceq $Method })
        }
    }

    It 'matches the whole name without regard to case and white space' -ForEach @(
        @{ Want = 'sign in'; Expected = 'Sign in' }
        @{ Want = '  Sign   IN '; Expected = 'Sign in' }
        @{ Want = "Sig$([char]0x00AD)n$([char]0x200B) in"; Expected = 'Sign in' }
        @{ Want = "Re$([char]0x0301)sume$([char]0x0301)"; Expected = "R$([char]0x00E9)sum$([char]0x00E9)" }
    ) {
        $nodes = @(
            (New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Sign in' -Backend 10)
            (New-WebTestAxNode -Id 'b2' -Role 'button' -Name "R$([char]0x00E9)sum$([char]0x00E9)" -Backend 11)
            (New-WebTestAxNode -Id 'b3' -Role 'button' -Name 'Sign in later' -Backend 12)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = (New-FbTree -Nodes $nodes) })
        $forest = Read-WebPageForest -Connection $t.Connection -DeadlineUtc $t.Clock.Now.AddSeconds(5)
        $found = Find-WebElement -Forest $forest -Role 'button' -Name $Want
        Assert-Equal -Expected 1 -Actual $found.Count -Because "the wanted name [$Want] matches one whole name"
        Assert-StringEqual -Expected $Expected -Actual ([string]$found[0].Name)
    }

    It 'matches part of a name only with match contains' {
        $nodes = @(
            (New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Save' -Backend 10)
            (New-WebTestAxNode -Id 'b2' -Role 'button' -Name 'Save draft' -Backend 11)
            (New-WebTestAxNode -Id 'b3' -Role 'button' -Name '  SAVE   As Copy ' -Backend 12)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = (New-FbTree -Nodes $nodes) })
        $forest = Read-WebPageForest -Connection $t.Connection -DeadlineUtc $t.Clock.Now.AddSeconds(5)
        Assert-Equal -Expected 1 -Actual (Find-WebElement -Forest $forest -Role 'button' -Name 'Save').Count -Because 'exact is the default'
        Assert-Equal -Expected 3 -Actual (Find-WebElement -Forest $forest -Role 'button' -Name 'Save' -Match contains).Count
    }

    It 'reads role img as image and compares other roles exactly' {
        $nodes = @(
            (New-WebTestAxNode -Id 'i1' -Role 'image' -Name 'Logo' -Backend 10)
            (New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Go' -Backend 11)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = (New-FbTree -Nodes $nodes) })
        $forest = Read-WebPageForest -Connection $t.Connection -DeadlineUtc $t.Clock.Now.AddSeconds(5)
        Assert-Equal -Expected 1 -Actual (Find-WebElement -Forest $forest -Role 'img' -Name 'Logo').Count -Because 'img is read as image'
        Assert-Equal -Expected 0 -Actual (Find-WebElement -Forest $forest -Role 'Button' -Name 'Go').Count -Because 'roles compare exactly'
    }

    It 'orders matches by document position across frames and picks nth' {
        $main = New-FbTree -Nodes @(
            (New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Go' -Backend 10)
            (New-WebTestAxNode -Id 'f1' -Role 'Iframe' -Backend 20)
            (New-WebTestAxNode -Id 'f2' -Role 'Iframe' -Backend 40)
        )
        $sameProcess = New-FbTree -Nodes @((New-WebTestAxNode -Id 'b2' -Role 'button' -Name 'Go' -Backend 30))
        $attached = New-FbTree -Nodes @((New-WebTestAxNode -Id 'b3' -Role 'button' -Name 'Go' -Backend 50))
        $page = New-WebTestPage -Ax @{ 'S1' = $main; 'S1|F1' = $sameProcess; 'S2' = $attached } -Describe @{
            20 = @{ backendNodeId = 20; nodeName = 'IFRAME'; frameId = 'F1' }
            40 = @{ backendNodeId = 40; nodeName = 'IFRAME'; frameId = 'F2' }
        }
        $t = New-WebTestConnection -Responder $page
        Add-WebTestEvent -Transport $t.Transport -Event @{ method = 'Target.attachedToTarget'; sessionId = 'S1'; params = @{ sessionId = 'S2'; targetInfo = @{ type = 'iframe'; targetId = 'F2' } } }
        $dl = $t.Clock.Now.AddSeconds(5)
        $result = InModuleScope Test.WebSession -Parameters @{ Conn = $t.Connection; Dl = $dl } {
            param($Conn, $Dl)
            @{
                Second = Find-WebTarget -Connection $Conn -Locator @{ role = 'button'; name = 'Go'; nth = 2 } -DeadlineUtc $Dl
                Third  = Find-WebTarget -Connection $Conn -Locator @{ role = 'button'; name = 'Go'; nth = 3 } -DeadlineUtc $Dl
            }
        }
        $order = @($result.Second.Matches | ForEach-Object { [int]$_.Address.BackendNodeId })
        Assert-StringEqual -Expected '10,30,50' -Actual ($order -join ',') -Because 'the page, then the same-process frame, then the attached frame'
        Assert-Equal -Expected 30 -Actual ([int]$result.Second.Target.Address.BackendNodeId) -Because 'nth 2 is the first frame''s button'
        Assert-StringEqual -Expected 'S1' -Actual ([string]$result.Second.Target.Address.SessionId)
        Assert-StringEqual -Expected 'S2' -Actual ([string]$result.Third.Target.Address.SessionId)
    }

    It 'fails at once on two matches without nth and lists both' {
        $nodes = @(
            (New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Delete' -Backend 10)
            (New-WebTestAxNode -Id 'b2' -Role 'button' -Name 'Delete' -Backend 11)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = (New-FbTree -Nodes $nodes) } -Quads @{ 10 = (Get-FbQuad 100 100); 11 = (Get-FbQuad 100 200) })
        $start = $t.Clock.Now
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $failure = Get-FbFailure { Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Delete' } -DeadlineUtc $start.AddSeconds(5) -Effect $effect }
        Assert-NotNull $failure 'two matches failed the step'
        Assert-StringEqual -Expected 'ambiguous' -Actual $failure.Kind
        Assert-Equal -Expected 2 -Actual @($failure.Candidates).Count
        Assert-Equal -Expected 2 -Actual $failure.MatchCount
        Assert-Equal -Expected 0 -Actual @($t.Transport.State.Sent | Where-Object { ([string]$_['method']).StartsWith('Input.') -or [string]$_['method'] -ceq 'DOM.focus' }).Count
        Assert-True (($t.Clock.Now - $start).TotalMilliseconds -lt 100) 'the step failed without polling'
    }

    It 'keeps polling while nothing matches and fails as not_found at the deadline' {
        $nodes = @((New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Go' -Backend 10))
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = (New-FbTree -Nodes $nodes) })
        $start = $t.Clock.Now
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $failure = Get-FbFailure { Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Missing' } -DeadlineUtc $start.AddSeconds(5) -Effect $effect }
        Assert-StringEqual -Expected 'not_found' -Actual $failure.Kind
        Assert-False $failure.Retryable 'the deadline failure is final'
        $elapsed = ($t.Clock.Now - $start).TotalMilliseconds
        Assert-True ($elapsed -ge 4900 -and $elapsed -le 5000) "thrown at $elapsed ms on the clock"
        $reads = (Get-FbSent -Test $t -Method 'Accessibility.getFullAXTree').Count
        Assert-True ($reads -ge 40 -and $reads -le 50) "$reads forest reads"
        Assert-Equal -Expected 0 -Actual @($t.Transport.State.Sent | Where-Object { ([string]$_['method']).StartsWith('Input.') }).Count
    }

    It 'names elements with the same name and another role when nothing matches' {
        $nodes = @(
            (New-WebTestAxNode -Id 's1' -Role 'spinbutton' -Name 'Quantity' -Backend 10)
            (New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Order' -Backend 11)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = (New-FbTree -Nodes $nodes) })
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $failure = Get-FbFailure { Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'quantity' } -DeadlineUtc $t.Clock.Now.AddSeconds(1) -Effect $effect }
        Assert-StringEqual -Expected 'not_found' -Actual $failure.Kind
        $roles = @($failure.Candidates | ForEach-Object { [string]$_.role })
        Assert-StringEqual -Expected 'spinbutton' -Actual ($roles -join ',')
        Assert-Equal -Expected 0 -Actual $failure.MatchCount
    }

    It 'finds an element that appears on a later poll' {
        $later = {
            param($Message, $State, $Read)
            $null = $Message, $State
            $nodes = if ($Read -ge 4) { @((New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Go' -Backend 10)) } else { @() }
            New-FbTree -Nodes $nodes
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $later } -Quads @{ 10 = (Get-FbQuad 100 100) })
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $null = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect
        Assert-Equal -Expected 4 -Actual (Get-FbSent -Test $t -Method 'Accessibility.getFullAXTree').Count -Because 'found on the fourth read'
        Assert-True $effect.Acknowledged 'the click was delivered'
    }

    It 'resolves css in the top document, keeps visible matches and refuses a bad selector' {
        $hidden = New-WebTestAxNode -Id 'h' -Role 'button' -Name 'Hidden' -Backend 60 -Ignored
        $hidden['ignoredReasons'] = @(@{ name = 'notRendered' })
        $page = New-WebTestPage -Quads @{ 50 = (Get-FbQuad 100 100); 60 = (Get-FbQuad 100 200) } -Describe @{
            'node:5' = @{ nodeId = 5; backendNodeId = 50; nodeName = 'BUTTON' }
            'node:6' = @{ nodeId = 6; backendNodeId = 60; nodeName = 'BUTTON' }
        } -Partial @{ 50 = (New-WebTestAxNode -Id 'v' -Role 'button' -Name 'Visible' -Backend 50); 60 = $hidden } -Override @{
            'DOM.querySelectorAll' = {
                param($Message, $State)
                $null = $State
                if ([string]$Message['params']['selector'] -ceq 'button[') { return (New-WebTestError -Message $Message -Code -32000 -Text 'DOM Error while querying') }
                New-WebTestReply -Message $Message -Result @{ nodeIds = @(5, 6) }
            }
        }
        $t = New-WebTestConnection -Responder $page
        $dl = $t.Clock.Now.AddSeconds(5)
        $found = InModuleScope Test.WebSession -Parameters @{ Conn = $t.Connection; Dl = $dl } {
            param($Conn, $Dl)
            Find-WebCssElement -Connection $Conn -Selector 'button.go' -DeadlineUtc $Dl
        }
        Assert-Equal -Expected 1 -Actual @($found).Count -Because 'the hidden match is dropped'
        Assert-Equal -Expected 50 -Actual ([int]$found[0].Address.BackendNodeId)
        Assert-StringEqual -Expected 'Visible' -Actual ([string]$found[0].Name)
        Assert-Equal -Expected 0 -Actual @($found[0].Address.Owners).Count
        $query = (Get-FbSent -Test $t -Method 'DOM.querySelectorAll')[0]
        Assert-StringEqual -Expected 'S1' -Actual ([string]$query['sessionId']) -Because 'only the top document is queried'
        $failure = Get-FbFailure {
            InModuleScope Test.WebSession -Parameters @{ Conn = $t.Connection; Dl = $dl } {
                param($Conn, $Dl)
                Find-WebCssElement -Connection $Conn -Selector 'button[' -DeadlineUtc $Dl
            }
        }
        Assert-StringEqual -Expected 'invalid_step' -Actual $failure.Kind
        Assert-Match -Pattern '^css: ' -Actual $failure.Detail
    }
}

Describe 'the click point' {
    BeforeAll {
        function New-FbTree {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory accessibility tree.')]
            param([object[]]$Nodes = @(), [string[]]$Top)
            $Nodes = @($Nodes | Where-Object { $null -ne $_ })
            if ($null -eq $Top) { $Top = @($Nodes | ForEach-Object { [string]$_['nodeId'] }) }
            $root = New-WebTestAxNode -Id 'root' -Role 'RootWebArea' -Name 'Fixture' -Children $Top
            return , (@($root) + @($Nodes))
        }
        function Get-FbQuad {
            param([double]$X, [double]$Y, [double]$Half = 10)
            return , @(($X - $Half), ($Y - $Half), ($X + $Half), ($Y - $Half), ($X + $Half), ($Y + $Half), ($X - $Half), ($Y + $Half))
        }
        function Get-FbFailure {
            param([Parameter(Mandatory)][scriptblock]$Action)
            try {
                $null = & $Action
            } catch {
                $failure = Get-WebFailureData -ErrorRecord $_
                if ($null -eq $failure) { throw }
                return $failure
            }
            return $null
        }
        function Invoke-FbClickPoint {
            param([Parameter(Mandatory)][hashtable]$Test, [Parameter(Mandatory)][hashtable]$Address)
            $dl = $Test.Clock.Now.AddSeconds(5)
            return (InModuleScope Test.WebSession -Parameters @{ Conn = $Test.Connection; Where = $Address; Dl = $dl } {
                    param($Conn, $Where, $Dl)
                    Resolve-WebClickPoint -Connection $Conn -Address $Where -DeadlineUtc $Dl
                })
        }
    }

    It 'adds the content origin of each owner frame to the local point' {
        $page = New-WebTestPage -Quads @{ 70 = (Get-FbQuad 314.5 78.3) } -Box @{ 20 = @(47, 384.4, 300, 384.4, 300, 600, 47, 600); 40 = @(15, 91.8, 200, 91.8, 200, 300, 15, 300) }
        $t = New-WebTestConnection -Responder $page
        $address = @{ SessionId = 'S3'; BackendNodeId = 70; Owners = @(@{ SessionId = 'S1'; BackendNodeId = 20 }, @{ SessionId = 'S2'; BackendNodeId = 40 }) }
        $point = InModuleScope Test.WebSession -Parameters @{ Conn = $t.Connection; Where = $address; Dl = $t.Clock.Now.AddSeconds(5) } {
            param($Conn, $Where, $Dl)
            Get-WebPagePoint -Connection $Conn -Address $Where -DeadlineUtc $Dl
        }
        Assert-True ([Math]::Abs($point.X - (314.5 + 47 + 15)) -lt 1e-6) "x is $($point.X)"
        Assert-True ([Math]::Abs($point.Y - (78.3 + 384.4 + 91.8)) -lt 1e-6) "y is $($point.Y)"
        Assert-True ([Math]::Abs($point.Origins[0].X - 47) -lt 1e-9 -and [Math]::Abs($point.Origins[1].Y - 91.8) -lt 1e-9) 'the origins are those of the owners, in order'
    }

    It 'asks the hit test in whole document coordinates' {
        $page = New-WebTestPage -Quads @{ 10 = (Get-FbQuad 61.27 765.09) } -Metrics @{ S1 = @{ clientWidth = 1280; clientHeight = 800; pageX = 0; pageY = 2506 } }
        $t = New-WebTestConnection -Responder $page
        $point = Invoke-FbClickPoint -Test $t -Address @{ SessionId = 'S1'; BackendNodeId = 10; Owners = @() }
        Assert-True ([Math]::Abs($point.Y - 765.09) -lt 1e-6) 'the click point stays in viewport coordinates'
        $hit = @($t.Transport.State.Sent | Where-Object { [string]$_['method'] -ceq 'DOM.getNodeForLocation' })
        Assert-Equal -Expected 1 -Actual $hit.Count
        $x = $hit[0]['params']['x']
        $y = $hit[0]['params']['y']
        Assert-Equal -Expected 61 -Actual $x
        Assert-Equal -Expected 3271 -Actual $y
        Assert-True (($x -is [int] -or $x -is [long]) -and ($y -is [int] -or $y -is [long])) "x is $($x.GetType().Name) and y is $($y.GetType().Name), never a fraction"
    }

    It 'accepts a hit on a descendant and names a covering element' {
        $page = New-WebTestPage -Quads @{ 10 = (Get-FbQuad 100 100) } -Hit @{ S1 = 11 } -Describe @{
            10 = @{ backendNodeId = 10; nodeName = 'BUTTON'; children = @(@{ backendNodeId = 11; nodeName = 'SPAN' }) }
        }
        $t = New-WebTestConnection -Responder $page
        $point = Invoke-FbClickPoint -Test $t -Address @{ SessionId = 'S1'; BackendNodeId = 10; Owners = @() }
        Assert-Equal -Expected 100.0 -Actual $point.X
        $covered = New-WebTestPage -Quads @{ 10 = (Get-FbQuad 100 100) } -Hit @{ S1 = 12 } -Describe @{
            10 = @{ backendNodeId = 10; nodeName = 'BUTTON'; children = @(@{ backendNodeId = 11; nodeName = 'SPAN' }) }
            12 = @{ backendNodeId = 12; nodeName = 'DIV'; attributes = @('id', 'cover') }
        }
        $t2 = New-WebTestConnection -Responder $covered
        $failure = Get-FbFailure { Invoke-FbClickPoint -Test $t2 -Address @{ SessionId = 'S1'; BackendNodeId = 10; Owners = @() } }
        Assert-StringEqual -Expected 'not_actionable' -Actual $failure.Kind
        Assert-StringEqual -Expected 'covered by <DIV id=cover>' -Actual $failure.Detail
        Assert-True $failure.Retryable 'a cover may go away'
    }

    It 'waits while the element <Condition>' -ForEach @(
        @{ Condition = 'moves'; Detail = 'moving' }
        @{ Condition = 'has no box'; Detail = 'no box' }
        @{ Condition = 'lies outside the viewport'; Detail = 'outside viewport' }
    ) {
        $quads = switch ($Condition) {
            'moves' {
                $moving = @{ X = 100.0 }
                @{ 10 = { param($Message, $State) $null = $Message, $State; $moving.X += 5; Get-FbQuad $moving.X 100 } }
            }
            'has no box' { @{} }
            default { @{ 10 = (Get-FbQuad 2000 100) } }
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Quads $quads)
        $failure = Get-FbFailure { Invoke-FbClickPoint -Test $t -Address @{ SessionId = 'S1'; BackendNodeId = 10; Owners = @() } }
        Assert-StringEqual -Expected 'not_actionable' -Actual $failure.Kind
        Assert-StringEqual -Expected $Detail -Actual $failure.Detail
        Assert-True $failure.Retryable 'the caller resolves again'
    }

    It 'resolves again after a detached node and sends no input in between' {
        $nodes = @((New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Go' -Backend 10))
        $scrolls = @{ Count = 0 }
        $page = New-WebTestPage -Ax @{ S1 = (New-FbTree -Nodes $nodes) } -Quads @{ 10 = (Get-FbQuad 100 100) } -Override @{
            'DOM.scrollIntoViewIfNeeded' = {
                param($Message, $State)
                $null = $State
                $scrolls.Count++
                if ($scrolls.Count -eq 1) { return (New-WebTestError -Message $Message -Code -32000 -Text 'Node is detached from document') }
                New-WebTestReply -Message $Message
            }
        }
        $t = New-WebTestConnection -Responder $page
        $effect = @{ Dispatched = $false; Acknowledged = $false }
        $null = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect
        $methods = @($t.Transport.State.Sent | ForEach-Object { [string]$_['method'] })
        $secondScroll = -1
        $seen = 0
        for ($i = 0; $i -lt $methods.Count; $i++) {
            if ($methods[$i] -ceq 'DOM.scrollIntoViewIfNeeded') { $seen++; if ($seen -eq 2) { $secondScroll = $i } }
        }
        $firstInput = [array]::FindIndex([string[]]$methods, [Predicate[string]] { param($m) $m.StartsWith('Input.') })
        Assert-Equal -Expected 2 -Actual $scrolls.Count
        Assert-Equal -Expected 2 -Actual @($methods | Where-Object { $_ -ceq 'Accessibility.getFullAXTree' }).Count -Because 'the target was resolved again'
        Assert-True ($firstInput -gt $secondScroll) 'no input before the second resolution'
        Assert-Equal -Expected 1 -Actual @($t.Transport.State.Sent | Where-Object { [string]$_['method'] -ceq 'Input.dispatchMouseEvent' -and [string]$_['params']['type'] -ceq 'mousePressed' }).Count
    }
}

Describe 'page operations' {
    BeforeAll {
        function New-FbTree {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory accessibility tree.')]
            param([object[]]$Nodes = @(), [string[]]$Top)
            $Nodes = @($Nodes | Where-Object { $null -ne $_ })
            if ($null -eq $Top) { $Top = @($Nodes | ForEach-Object { [string]$_['nodeId'] }) }
            $root = New-WebTestAxNode -Id 'root' -Role 'RootWebArea' -Name 'Fixture' -Children $Top
            return , (@($root) + @($Nodes))
        }
        function Get-FbQuad {
            param([double]$X, [double]$Y, [double]$Half = 10)
            return , @(($X - $Half), ($Y - $Half), ($X + $Half), ($Y - $Half), ($X + $Half), ($Y + $Half), ($X - $Half), ($Y + $Half))
        }
        function Get-FbFailure {
            param([Parameter(Mandatory)][scriptblock]$Action)
            try {
                $null = & $Action
            } catch {
                $failure = Get-WebFailureData -ErrorRecord $_
                if ($null -eq $failure) { throw }
                return $failure
            }
            return $null
        }
        function Get-FbSent {
            param([Parameter(Mandatory)][hashtable]$Test, [string]$Method, [string]$Type)
            return , @($Test.Transport.State.Sent | Where-Object {
                    (-not $Method -or [string]$_['method'] -ceq $Method) -and (-not $Type -or ($_['params'] -is [System.Collections.IDictionary] -and [string]$_['params']['type'] -ceq $Type))
                })
        }
        function Get-FbInputCount {
            param([Parameter(Mandatory)][hashtable]$Test)
            return @($Test.Transport.State.Sent | Where-Object { ([string]$_['method']).StartsWith('Input.') }).Count
        }
        function New-FbEffect { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory table.')] param() return @{ Dispatched = $false; Acknowledged = $false } }
        # A main-frame event of the owned page.
        function New-FbFrameEvent {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory event message.')]
            param([Parameter(Mandatory)][string]$Method, [string]$Url, [string]$Unreachable, [int]$AfterMs = 0)
            $params = if ($Method -ceq 'Page.frameNavigated') {
                $frame = @{ id = 'T1'; url = $Url }
                if ($Unreachable) { $frame['unreachableUrl'] = $Unreachable }
                @{ frame = $frame }
            } elseif ($Method -ceq 'Page.navigatedWithinDocument') {
                @{ frameId = 'T1'; url = $Url }
            } else {
                @{ frameId = 'T1' }
            }
            $message = [ordered]@{ method = $Method; sessionId = 'S1'; params = $params }
            if ($AfterMs -gt 0) { $message['_afterMs'] = $AfterMs }
            return $message
        }
        # Mouse events answered at once, with what each release adds.
        function New-FbMouseOverride {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory responder override.')]
            param([scriptblock]$OnRelease)
            # The closure reads OnRelease; the analyzer does not see into it.
            $null = $OnRelease
            # A closure does not see the functions of this scope: carry the reply in.
            $reply = ${function:New-WebTestReply}
            return @{
                'Input.dispatchMouseEvent' = {
                    param($Message, $State)
                    $null = $State
                    if ([string]$Message['params']['type'] -ceq 'mouseReleased' -and $OnRelease) { return (& $OnRelease $Message) }
                    & $reply -Message $Message
                }.GetNewClosure()
            }
        }
        $script:FbGo = New-FbTree -Nodes @((New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Go' -Backend 10))
        $script:FbGoQuads = @{ 10 = (Get-FbQuad 100 100) }
        $script:FbSelectFunction = InModuleScope Test.WebSession { $script:WebSelectFunction }
    }

    It 'clicks with move, press and release at the point and then settles' {
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $script:FbGo } -Quads $script:FbGoQuads)
        $start = $t.Clock.Now
        $effect = New-FbEffect
        $null = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $start.AddSeconds(5) -Effect $effect
        $mouse = Get-FbSent -Test $t -Method 'Input.dispatchMouseEvent'
        Assert-Equal -Expected 3 -Actual $mouse.Count
        Assert-StringEqual -Expected 'mouseMoved,mousePressed,mouseReleased' -Actual (@($mouse | ForEach-Object { [string]$_['params']['type'] }) -join ',')
        foreach ($sent in $mouse) {
            Assert-StringEqual -Expected 'S1' -Actual ([string]$sent['sessionId'])
            Assert-Equal -Expected 100 -Actual ([double]$sent['params']['x'])
            Assert-Equal -Expected 100 -Actual ([double]$sent['params']['y'])
        }
        Assert-StringEqual -Expected 'none/0' -Actual "$($mouse[0]['params']['button'])/$($mouse[0]['params']['buttons'])"
        Assert-StringEqual -Expected 'left/1/1' -Actual "$($mouse[1]['params']['button'])/$($mouse[1]['params']['buttons'])/$($mouse[1]['params']['clickCount'])"
        Assert-StringEqual -Expected 'left/0/1' -Actual "$($mouse[2]['params']['button'])/$($mouse[2]['params']['buttons'])/$($mouse[2]['params']['clickCount'])"
        Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'both effect facts are true'
        Assert-True (($t.Clock.Now - $start).TotalMilliseconds -ge 500) 'the click settled for the quiet time'
    }

    It 'waits for a disabled button and clicks it once it is enabled' {
        $later = {
            param($Message, $State, $Read)
            $null = $Message, $State
            $props = if ($Read -le 3) { @{ disabled = $true } } else { @{ disabled = $false } }
            New-FbTree -Nodes @((New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Go' -Backend 10 -Props $props))
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $later } -Quads $script:FbGoQuads)
        $effect = New-FbEffect
        $null = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect
        Assert-Equal -Expected 1 -Actual (Get-FbSent -Test $t -Method 'Input.dispatchMouseEvent' -Type 'mousePressed').Count
        Assert-Equal -Expected 4 -Actual (Get-FbSent -Test $t -Method 'Accessibility.getFullAXTree').Count
    }

    It 'sends no input to a button that stays disabled' {
        $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Go' -Backend 10 -Props @{ disabled = $true }))
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $tree } -Quads $script:FbGoQuads)
        $start = $t.Clock.Now
        $effect = New-FbEffect
        $failure = Get-FbFailure { Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $start.AddSeconds(3) -Effect $effect }
        Assert-StringEqual -Expected 'not_actionable' -Actual $failure.Kind
        Assert-StringEqual -Expected 'disabled' -Actual $failure.Detail
        $elapsed = ($t.Clock.Now - $start).TotalMilliseconds
        Assert-True ($elapsed -ge 2900 -and $elapsed -le 3000) "thrown at $elapsed ms on the clock"
        Assert-Equal -Expected 0 -Actual (Get-FbInputCount -Test $t)
        Assert-False $effect.Dispatched 'nothing was sent'
    }

    It 'leaves the effect uncertain when the release gets no reply' {
        $override = New-FbMouseOverride -OnRelease { param($Message) $null = $Message }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $script:FbGo } -Quads $script:FbGoQuads -Override $override)
        $effect = New-FbEffect
        $failure = Get-FbFailure { Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(30) -Effect $effect }
        Assert-StringEqual -Expected 'page_lost' -Actual $failure.Kind
        Assert-StringEqual -Expected 'no reply to Input.dispatchMouseEvent' -Actual $failure.Detail
        Assert-True $effect.Dispatched 'the click was handed to the browser'
        Assert-False $effect.Acknowledged 'its delivery is unknown'
        Assert-Equal -Expected 1 -Actual (Get-FbSent -Test $t -Method 'Input.dispatchMouseEvent' -Type 'mousePressed').Count -Because 'a click of unknown delivery is never repeated'
    }

    It 'clicks the one match of a css locator' {
        $page = New-WebTestPage -Quads @{ 10 = (Get-FbQuad 120 140) } -Describe @{ 'node:5' = @{ nodeId = 5; backendNodeId = 10; nodeName = 'BUTTON' } } `
            -Partial @{ 10 = (New-WebTestAxNode -Id 'g' -Role 'button' -Name 'Go' -Backend 10) } -Override @{
            'DOM.querySelectorAll' = { param($Message, $State) $null = $State; New-WebTestReply -Message $Message -Result @{ nodeIds = @(5) } }
        }
        $t = New-WebTestConnection -Responder $page
        $effect = New-FbEffect
        $null = Invoke-WebPageClick -Connection $t.Connection -Locator @{ css = '#go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect
        $queries = Get-FbSent -Test $t -Method 'DOM.querySelectorAll'
        Assert-Equal -Expected 1 -Actual $queries.Count
        Assert-StringEqual -Expected '#go' -Actual ([string]$queries[0]['params']['selector'])
        $mouse = Get-FbSent -Test $t -Method 'Input.dispatchMouseEvent'
        Assert-Equal -Expected 3 -Actual $mouse.Count
        Assert-True (@($mouse | Where-Object { [double]$_['params']['x'] -eq 120 -and [double]$_['params']['y'] -eq 140 }).Count -eq 3) 'the three events go to its point'
        Assert-Equal -Expected 0 -Actual (Get-FbSent -Test $t -Method 'Accessibility.getFullAXTree').Count
    }

    It 'leaves a check box that already has the state asked for' {
        $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 'c1' -Role 'checkbox' -Name 'Remember me' -Backend 10 -Props @{ checked = 'true' }))
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $tree } -Quads $script:FbGoQuads)
        $effect = New-FbEffect
        $result = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'checkbox'; name = 'Remember me' } -Checked $true -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect
        Assert-False $result.Navigated 'nothing happened'
        Assert-Equal -Expected 0 -Actual (Get-FbInputCount -Test $t)
        Assert-False $effect.Dispatched 'no input was sent'
    }

    It 'clicks a check box and reads its state back; fails as expectation when it did not change' {
        foreach ($flips in $true, $false) {
            $box = @{ Checked = 'false'; Flips = $flips }
            $tree = { param($Message, $State, $Read) $null = $Message, $State, $Read; New-FbTree -Nodes @((New-WebTestAxNode -Id 'c1' -Role 'checkbox' -Name 'Remember me' -Backend 10 -Props @{ checked = $box.Checked })) }
            $partial = { param($Message, $State) $null = $Message, $State; New-WebTestAxNode -Id 'c1' -Role 'checkbox' -Name 'Remember me' -Backend 10 -Props @{ checked = $box.Checked } }
            $override = New-FbMouseOverride -OnRelease { param($Message) if ($box.Flips) { $box.Checked = 'true' }; New-WebTestReply -Message $Message }
            $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $tree } -Quads $script:FbGoQuads -Partial @{ 10 = $partial } -Override $override)
            $effect = New-FbEffect
            $failure = Get-FbFailure { Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'checkbox'; name = 'Remember me' } -Checked $true -DeadlineUtc $t.Clock.Now.AddSeconds(10) -Effect $effect }
            Assert-Equal -Expected 1 -Actual (Get-FbSent -Test $t -Method 'Input.dispatchMouseEvent' -Type 'mousePressed').Count
            Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'both effect facts are true'
            if ($flips) {
                Assert-Null $failure 'the box changed and the step passed'
                Assert-True ((Get-FbSent -Test $t -Method 'Accessibility.getPartialAXTree').Count -ge 1) 'the state was read back'
            } else {
                Assert-StringEqual -Expected 'expectation' -Actual $failure.Kind
                Assert-StringEqual -Expected 'checked is false' -Actual $failure.Detail
            }
        }
    }

    It 'fills by focus, select-all and insertText and reads the value back' {
        $field = @{ Value = '' }
        $main = New-FbTree -Nodes @((New-WebTestAxNode -Id 'f2' -Role 'Iframe' -Backend 40))
        $inner = { param($Message, $State, $Read) $null = $Message, $State, $Read; New-FbTree -Nodes @((New-WebTestAxNode -Id 't1' -Role 'textbox' -Name 'Name' -Backend 10 -Props @{ editable = 'plaintext' })) }
        $partial = { param($Message, $State) $null = $Message, $State; New-WebTestAxNode -Id 't1' -Role 'textbox' -Name 'Name' -Backend 10 -Props @{ editable = 'plaintext' } -Value $field.Value }
        $page = New-WebTestPage -Ax @{ S1 = $main; S2 = $inner } -Quads @{ 10 = (Get-FbQuad 50 50) } -Partial @{ 10 = $partial } `
            -Describe @{ 40 = @{ backendNodeId = 40; nodeName = 'IFRAME'; frameId = 'F2' }; 10 = @{ backendNodeId = 10; nodeName = 'INPUT'; attributes = @('type', 'text') } } -Override @{
            'Input.insertText' = { param($Message, $State) $null = $State; $field.Value = [string]$Message['params']['text']; New-WebTestReply -Message $Message }
        }
        $t = New-WebTestConnection -Responder $page
        Add-WebTestEvent -Transport $t.Transport -Event @{ method = 'Target.attachedToTarget'; sessionId = 'S1'; params = @{ sessionId = 'S2'; targetInfo = @{ type = 'iframe'; targetId = 'F2' } } }
        $effect = New-FbEffect
        $typedText = 'Maria Silva'
        $null = Invoke-WebPageFill -Connection $t.Connection -Locator @{ role = 'textbox'; name = 'Name' } -Text $typedText -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect
        $steps = @($t.Transport.State.Sent | Where-Object { [string]$_['method'] -cin @('DOM.focus', 'Input.dispatchKeyEvent', 'Input.insertText') })
        Assert-Equal -Expected 4 -Actual $steps.Count
        Assert-StringEqual -Expected 'DOM.focus' -Actual ([string]$steps[0]['method'])
        Assert-StringEqual -Expected 'S2' -Actual ([string]$steps[0]['sessionId']) -Because 'focus goes to the target''s session'
        Assert-StringEqual -Expected 'rawKeyDown' -Actual ([string]$steps[1]['params']['type'])
        Assert-StringEqual -Expected 'selectAll' -Actual (@($steps[1]['params']['commands']) -join ',')
        Assert-StringEqual -Expected 'keyUp' -Actual ([string]$steps[2]['params']['type'])
        Assert-StringEqual -Expected 'Input.insertText' -Actual ([string]$steps[3]['method'])
        foreach ($sent in $steps[1..3]) { Assert-StringEqual -Expected 'S1' -Actual ([string]$sent['sessionId']) -Because 'input goes to the page session' }
        Assert-StringEqual -Expected $typedText -Actual ([string]$steps[3]['params']['text'])
        Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'both effect facts are true'
        Assert-True ((Get-FbSent -Test $t -Method 'Accessibility.getPartialAXTree').Count -ge 1) 'the value was read back'
    }

    It 'fails a fill whose value reads back changed, naming lengths only' {
        $field = @{ Value = '' }
        $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 't1' -Role 'textbox' -Name 'Name' -Backend 10 -Props @{ editable = 'plaintext' }))
        $partial = { param($Message, $State) $null = $Message, $State; New-WebTestAxNode -Id 't1' -Role 'textbox' -Name 'Name' -Backend 10 -Props @{ editable = 'plaintext' } -Value $field.Value }
        $page = New-WebTestPage -Ax @{ S1 = $tree } -Quads $script:FbGoQuads -Partial @{ 10 = $partial } -Override @{
            'Input.insertText' = { param($Message, $State) $null = $State; $field.Value = ([string]$Message['params']['text']).Substring(0, 5); New-WebTestReply -Message $Message }
        }
        $t = New-WebTestConnection -Responder $page
        $effect = New-FbEffect
        $caught = $null
        try {
            $null = Invoke-WebPageFill -Connection $t.Connection -Locator @{ role = 'textbox'; name = 'Name' } -Text 'abcdefghi' -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect
        } catch {
            $caught = $_
        }
        Assert-NotNull $caught 'the fill failed'
        $failure = Get-WebFailureData -ErrorRecord $caught
        Assert-StringEqual -Expected 'expectation' -Actual $failure.Kind
        Assert-StringEqual -Expected 'value differs: wanted 9 characters, read 5' -Actual $failure.Detail
        $members = @($caught.Exception.Message, $caught.Exception.ToString(), (ConvertTo-Json -InputObject $failure -Depth 8 -Compress), [string]$caught)
        foreach ($member in $members) { Assert-False ($member.Contains('abcde')) "a member of the exception holds the text: $member" }
    }

    It 'compares only the length for a password field' {
        $field = @{ Value = '' }
        $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 't1' -Role 'textbox' -Name 'Password' -Backend 10 -Props @{ editable = 'plaintext' }))
        $partial = { param($Message, $State) $null = $Message, $State; New-WebTestAxNode -Id 't1' -Role 'textbox' -Name 'Password' -Backend 10 -Props @{ editable = 'plaintext' } -Value $field.Value }
        $page = New-WebTestPage -Ax @{ S1 = $tree } -Quads $script:FbGoQuads -Partial @{ 10 = $partial } -Describe @{ 10 = @{ backendNodeId = 10; nodeName = 'INPUT'; attributes = @('type', 'PASSWORD') } } -Override @{
            'Input.insertText' = { param($Message, $State) $null = $State; $field.Value = [string]::new([char]0x2022, ([string]$Message['params']['text']).Length); New-WebTestReply -Message $Message }
        }
        $t = New-WebTestConnection -Responder $page
        $effect = New-FbEffect
        $failure = Get-FbFailure { Invoke-WebPageFill -Connection $t.Connection -Locator @{ role = 'textbox'; name = 'Password' } -Text 'hunter2' -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect }
        Assert-Null $failure 'bullets of the same length pass'
        Assert-True $effect.Acknowledged 'the text was inserted'
    }

    It 'sends no input to a read-only or disabled field' {
        foreach ($props in @(@{ editable = 'plaintext'; readonly = $true }, @{ editable = 'plaintext'; disabled = $true })) {
            $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 't1' -Role 'textbox' -Name 'Name' -Backend 10 -Props $props))
            $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $tree } -Quads $script:FbGoQuads)
            $effect = New-FbEffect
            $failure = Get-FbFailure { Invoke-WebPageFill -Connection $t.Connection -Locator @{ role = 'textbox'; name = 'Name' } -Text 'x' -DeadlineUtc $t.Clock.Now.AddSeconds(1) -Effect $effect }
            Assert-StringEqual -Expected 'not_actionable' -Actual $failure.Kind
            Assert-Equal -Expected 0 -Actual (Get-FbInputCount -Test $t)
            Assert-Equal -Expected 0 -Actual (Get-FbSent -Test $t -Method 'DOM.focus').Count
            Assert-False $effect.Dispatched 'nothing was sent'
        }
    }

    It 'selects through the fixed function and handles <Reason>' -ForEach @(
        @{ Reason = 'a changed selection'; Ok = $true; Changed = $true; Why = ''; Kind = ''; Detail = ''; Dispatched = $true; Acknowledged = $true }
        @{ Reason = 'an unchanged selection'; Ok = $true; Changed = $false; Why = ''; Kind = ''; Detail = ''; Dispatched = $false; Acknowledged = $false }
        @{ Reason = 'no-option'; Ok = $false; Changed = $false; Why = 'no-option'; Kind = 'not_found'; Detail = 'option'; Dispatched = $false; Acknowledged = $false }
        @{ Reason = 'option-disabled'; Ok = $false; Changed = $false; Why = 'option-disabled'; Kind = 'not_actionable'; Detail = 'option disabled'; Dispatched = $false; Acknowledged = $false }
        @{ Reason = 'not-a-select'; Ok = $false; Changed = $false; Why = 'not-a-select'; Kind = 'not_actionable'; Detail = 'not-a-select'; Dispatched = $false; Acknowledged = $false }
        @{ Reason = 'multiple'; Ok = $false; Changed = $false; Why = 'multiple'; Kind = 'not_actionable'; Detail = 'multiple'; Dispatched = $false; Acknowledged = $false }
        @{ Reason = 'ambiguous-option'; Ok = $false; Changed = $false; Why = 'ambiguous-option'; Kind = 'ambiguous'; Detail = 'option'; Dispatched = $false; Acknowledged = $false }
    ) {
        $control = @{ Value = 'Red' }
        $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 'c1' -Role 'combobox' -Name 'Color' -Backend 10 -Value 'Red'))
        $partial = { param($Message, $State) $null = $Message, $State; New-WebTestAxNode -Id 'c1' -Role 'combobox' -Name 'Color' -Backend 10 -Value $control.Value }
        $outcome = if ($Ok) { @{ ok = $true; changed = $Changed; index = 1 } } else { @{ ok = $false; reason = $Why; options = @('Red', 'Blue', 'Blue'); count = 2 } }
        $page = New-WebTestPage -Ax @{ S1 = $tree } -Quads $script:FbGoQuads -Partial @{ 10 = $partial } -Override @{
            'DOM.resolveNode' = { param($Message, $State) $null = $State; New-WebTestReply -Message $Message -Result @{ object = @{ type = 'object'; objectId = 'obj-1' } } }
            'Runtime.callFunctionOn' = {
                param($Message, $State)
                $null = $State
                if ($outcome['changed'] -eq $true) { $control.Value = 'Blue' }
                New-WebTestReply -Message $Message -Result @{ result = @{ type = 'object'; value = $outcome } }
            }
        }
        $t = New-WebTestConnection -Responder $page
        $effect = New-FbEffect
        $failure = Get-FbFailure { Invoke-WebPageSelect -Connection $t.Connection -Locator @{ role = 'combobox'; name = 'Color' } -Option 'Blue' -DeadlineUtc $t.Clock.Now.AddSeconds(1) -Effect $effect }
        if ($Kind) {
            Assert-NotNull $failure "$Reason failed the step"
            Assert-StringEqual -Expected $Kind -Actual $failure.Kind
            Assert-StringEqual -Expected $Detail -Actual $failure.Detail
            if ($Why -ceq 'ambiguous-option') {
                Assert-Equal -Expected 2 -Actual $failure.MatchCount
                Assert-StringEqual -Expected 'option:Red,option:Blue,option:Blue' -Actual (@($failure.Candidates | ForEach-Object { "$($_.role):$($_.name)" }) -join ',')
            }
        } else {
            Assert-Null $failure "$Reason passed"
        }
        Assert-Equal -Expected $Dispatched -Actual $effect.Dispatched -Because 'Dispatched'
        Assert-Equal -Expected $Acknowledged -Actual $effect.Acknowledged -Because 'Acknowledged'
        $calls = Get-FbSent -Test $t -Method 'Runtime.callFunctionOn'
        Assert-True ($calls.Count -ge 1) 'the fixed function ran'
        foreach ($call in $calls) {
            Assert-True ([string]::Equals([string]$call['params']['functionDeclaration'], $script:FbSelectFunction, [StringComparison]::Ordinal)) 'the function is the fixed one'
            Assert-StringEqual -Expected 'Blue' -Actual ([string]@($call['params']['arguments'])[0]['value'])
            Assert-StringEqual -Expected 'obj-1' -Actual ([string]$call['params']['objectId'])
        }
        Assert-Equal -Expected $calls.Count -Actual (Get-FbSent -Test $t -Method 'Runtime.releaseObjectGroup').Count -Because 'every call releases its handle'
    }

    It 'passes an option that looks like script only as the bound argument' {
        $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 'c1' -Role 'combobox' -Name 'Color' -Backend 10 -Value 'Red'))
        $page = New-WebTestPage -Ax @{ S1 = $tree } -Quads $script:FbGoQuads -Override @{
            'DOM.resolveNode' = { param($Message, $State) $null = $State; New-WebTestReply -Message $Message -Result @{ object = @{ objectId = 'obj-1' } } }
            'Runtime.callFunctionOn' = { param($Message, $State) $null = $State; New-WebTestReply -Message $Message -Result @{ result = @{ value = @{ ok = $true; changed = $false; index = 0 } } } }
        }
        $t = New-WebTestConnection -Responder $page
        $options = @('Blue', "x'); alert(1); ('")
        foreach ($optionValue in $options) {
            $null = Invoke-WebPageSelect -Connection $t.Connection -Locator @{ role = 'combobox'; name = 'Color' } -Option $optionValue -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect (New-FbEffect)
        }
        $calls = Get-FbSent -Test $t -Method 'Runtime.callFunctionOn'
        Assert-Equal -Expected 2 -Actual $calls.Count
        for ($i = 0; $i -lt 2; $i++) {
            Assert-True ([string]::Equals([string]$calls[$i]['params']['functionDeclaration'], $script:FbSelectFunction, [StringComparison]::Ordinal)) 'the same fixed function'
            Assert-True ([string]::Equals([string]@($calls[$i]['params']['arguments'])[0]['value'], $options[$i], [StringComparison]::Ordinal)) 'the option, character for character'
        }
        $runtime = @($t.Transport.State.Sent | ForEach-Object { [string]$_['method'] } | Where-Object { $_.StartsWith('Runtime.') } | Sort-Object -Unique)
        Assert-StringEqual -Expected 'Runtime.callFunctionOn,Runtime.releaseObjectGroup' -Actual ($runtime -join ',') -Because 'no Runtime.evaluate, no other Runtime method'
    }

    It 'sends <Key> as <Type>' -ForEach (@(
            @{ Key = 'Enter'; KeyName = 'Enter'; Code = 'Enter'; Vk = 13; Type = 'keyDown'; Text = "`r" }
            @{ Key = 'Tab'; KeyName = 'Tab'; Code = 'Tab'; Vk = 9; Type = 'rawKeyDown'; Text = $null }
            @{ Key = 'Space'; KeyName = ' '; Code = 'Space'; Vk = 32; Type = 'keyDown'; Text = ' ' }
            @{ Key = 'Escape'; KeyName = 'Escape'; Code = 'Escape'; Vk = 27; Type = 'rawKeyDown'; Text = $null }
            @{ Key = 'Up'; KeyName = 'ArrowUp'; Code = 'ArrowUp'; Vk = 38; Type = 'rawKeyDown'; Text = $null }
            @{ Key = 'Down'; KeyName = 'ArrowDown'; Code = 'ArrowDown'; Vk = 40; Type = 'rawKeyDown'; Text = $null }
            @{ Key = 'Left'; KeyName = 'ArrowLeft'; Code = 'ArrowLeft'; Vk = 37; Type = 'rawKeyDown'; Text = $null }
            @{ Key = 'Right'; KeyName = 'ArrowRight'; Code = 'ArrowRight'; Vk = 39; Type = 'rawKeyDown'; Text = $null }
        ) + @(1..12 | ForEach-Object { @{ Key = "F$_"; KeyName = "F$_"; Code = "F$_"; Vk = 111 + $_; Type = 'rawKeyDown'; Text = $null } })) {
        $t = New-WebTestConnection -Responder (New-WebTestPage)
        $effect = New-FbEffect
        $null = Invoke-WebPagePress -Connection $t.Connection -Key $Key -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect
        $keys = Get-FbSent -Test $t -Method 'Input.dispatchKeyEvent'
        Assert-Equal -Expected 2 -Actual $keys.Count
        $down = $keys[0]['params']
        $up = $keys[1]['params']
        Assert-StringEqual -Expected $Type -Actual ([string]$down['type'])
        Assert-StringEqual -Expected 'keyUp' -Actual ([string]$up['type'])
        foreach ($keyEvent in $down, $up) {
            Assert-StringEqual -Expected $KeyName -Actual ([string]$keyEvent['key'])
            Assert-StringEqual -Expected $Code -Actual ([string]$keyEvent['code'])
            Assert-Equal -Expected $Vk -Actual ([int]$keyEvent['windowsVirtualKeyCode'])
            Assert-False $keyEvent.Contains('nativeVirtualKeyCode') 'no native key code, which runs browser shortcuts'
            Assert-False $keyEvent.Contains('commands') 'no editing command'
        }
        if ($null -ne $Text) {
            Assert-StringEqual -Expected $Text -Actual ([string]$down['text'])
            Assert-StringEqual -Expected $Text -Actual ([string]$down['unmodifiedText'])
        } else {
            Assert-False ($down.Contains('text') -or $down.Contains('unmodifiedText')) 'a key without text carries none'
        }
        Assert-False ($up.Contains('text')) 'the up event carries no text'
        foreach ($sent in $keys) { Assert-StringEqual -Expected 'S1' -Actual ([string]$sent['sessionId']) }
        Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'both effect facts are true'
    }

    It 'refuses a key outside the table' {
        $t = New-WebTestConnection -Responder (New-WebTestPage)
        $effect = New-FbEffect
        $failure = Get-FbFailure { Invoke-WebPagePress -Connection $t.Connection -Key 'Home' -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect }
        Assert-StringEqual -Expected 'invalid_step' -Actual $failure.Kind
        Assert-StringEqual -Expected 'key Home' -Actual $failure.Detail
        Assert-Equal -Expected 0 -Actual $t.Transport.State.Sent.Count
        Assert-False $effect.Dispatched 'nothing was sent'
    }

    It 'opens a URL and waits until loading stops and stays quiet' {
        $page = New-WebTestPage -Override @{
            'Page.navigate' = {
                param($Message, $State)
                $null = $State
                New-WebTestReply -Message $Message -Result @{ frameId = 'T1'; loaderId = 'L1' }
                New-FbFrameEvent -Method 'Page.frameStartedLoading'
                New-FbFrameEvent -Method 'Page.frameNavigated' -Url 'http://localhost:8080/next' -AfterMs 100
                New-FbFrameEvent -Method 'Page.frameStoppedLoading' -AfterMs 300
            }
        }
        $t = New-WebTestConnection -Responder $page
        $start = $t.Clock.Now
        $effect = New-FbEffect
        $result = Invoke-WebPageOpen -Connection $t.Connection -Url 'http://localhost:8080/next' -DeadlineUtc $start.AddSeconds(10) -Effect $effect
        $elapsed = ($t.Clock.Now - $start).TotalMilliseconds
        Assert-True ($elapsed -ge 800 -and $elapsed -lt 900) "returned at $elapsed ms: the stop at 300 ms plus 500 ms of quiet"
        Assert-True $result.Navigated 'the page navigated'
        Assert-StringEqual -Expected 'http://localhost:8080/next' -Actual ([string]$result.Url)
        $navigate = (Get-FbSent -Test $t -Method 'Page.navigate')[0]
        Assert-StringEqual -Expected 'S1' -Actual ([string]$navigate['sessionId'])
        Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'both effect facts are true'
    }

    It 'fails an open as navigation when <Case>' -ForEach @(
        @{ Case = 'the reply names a network error'; Detail = 'net::ERR_CONNECTION_REFUSED' }
        @{ Case = 'it is still loading at the deadline'; Detail = 'load did not finish' }
        @{ Case = 'the commit is unreachable'; Detail = 'unreachable: http://127.0.0.1:9/' }
        @{ Case = 'the navigate gets no reply'; Detail = 'no response' }
        @{ Case = 'the browser refuses the URL'; Detail = 'Cannot navigate to invalid URL' }
    ) {
        $mode = $Case
        $page = New-WebTestPage -Override @{
            'Page.navigate' = {
                param($Message, $State)
                $null = $State
                switch -Wildcard ($mode) {
                    '*network error' { New-WebTestReply -Message $Message -Result @{ frameId = 'T1'; errorText = 'net::ERR_CONNECTION_REFUSED' } }
                    '*still loading*' {
                        New-WebTestReply -Message $Message -Result @{ frameId = 'T1' }
                        New-FbFrameEvent -Method 'Page.frameStartedLoading'
                    }
                    '*unreachable' {
                        New-WebTestReply -Message $Message -Result @{ frameId = 'T1' }
                        New-FbFrameEvent -Method 'Page.frameStartedLoading'
                        New-FbFrameEvent -Method 'Page.frameNavigated' -Url 'chrome-error://chromewebdata/' -Unreachable 'http://127.0.0.1:9/' -AfterMs 20
                        New-FbFrameEvent -Method 'Page.frameStoppedLoading' -AfterMs 40
                    }
                    '*no reply' { }
                    default { New-WebTestError -Message $Message -Code -32000 -Text 'Cannot navigate to invalid URL' }
                }
            }
        }
        $t = New-WebTestConnection -Responder $page
        $effect = New-FbEffect
        $failure = Get-FbFailure { Invoke-WebPageOpen -Connection $t.Connection -Url 'http://127.0.0.1:9/' -DeadlineUtc $t.Clock.Now.AddSeconds(3) -Effect $effect }
        Assert-NotNull $failure "$Case failed the open"
        Assert-StringEqual -Expected 'navigation' -Actual $failure.Kind -Because 'never page_lost'
        Assert-StringEqual -Expected $Detail -Actual $failure.Detail
        Assert-False $failure.Retryable 'the open is not repeated'
        if ($Case -like '*refuses*') {
            Assert-False $effect.Dispatched 'Dispatched is back to its value on entry'
            Assert-False $effect.Acknowledged 'nothing was acknowledged'
        } else {
            Assert-True $effect.Dispatched 'the navigation was handed to the browser'
        }
    }

    It 'fails an open that starts a download as unsupported' {
        foreach ($shape in 'flag', 'event') {
            $mode = $shape
            $page = New-WebTestPage -Override @{
                'Page.navigate' = {
                    param($Message, $State)
                    $null = $State
                    if ($mode -ceq 'flag') {
                        New-WebTestReply -Message $Message -Result @{ frameId = 'T1'; errorText = 'net::ERR_ABORTED'; isDownload = $true }
                    } else {
                        [ordered]@{ method = 'Browser.downloadWillBegin'; params = @{ frameId = 'T1'; guid = 'g1'; url = 'http://localhost:8080/file.zip'; suggestedFilename = 'file.zip' } }
                        New-WebTestReply -Message $Message -Result @{ frameId = 'T1'; errorText = 'net::ERR_ABORTED' }
                    }
                }
            }
            $t = New-WebTestConnection -Responder $page
            $effect = New-FbEffect
            $failure = Get-FbFailure { Invoke-WebPageOpen -Connection $t.Connection -Url 'http://localhost:8080/file.zip' -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect }
            Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind -Because "the $shape shape is a download, never a navigation"
            Assert-StringEqual -Expected 'download' -Actual $failure.Detail
            Assert-True ($effect.Dispatched -and $effect.Acknowledged) "both effect facts are true ($shape)"
        }
    }

    It 'settles a navigation inside the document without a load event' {
        $override = New-FbMouseOverride -OnRelease {
            param($Message)
            New-WebTestReply -Message $Message
            New-FbFrameEvent -Method 'Page.frameStartedLoading' -AfterMs 5
            New-FbFrameEvent -Method 'Page.navigatedWithinDocument' -Url 'http://localhost:8080/#part' -AfterMs 10
            New-FbFrameEvent -Method 'Page.frameStoppedLoading' -AfterMs 15
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $script:FbGo } -Quads $script:FbGoQuads -Override $override)
        $result = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect (New-FbEffect)
        Assert-True $result.Navigated 'the fragment navigation counts'
        Assert-StringEqual -Expected 'http://localhost:8080/#part' -Actual ([string]$result.Url)
        Assert-False $t.Connection.Page.Loading 'loading stopped'
    }

    It 'sees a navigation that began before the release was answered' {
        $override = New-FbMouseOverride -OnRelease {
            param($Message)
            New-FbFrameEvent -Method 'Page.frameStartedLoading'
            New-FbFrameEvent -Method 'Page.frameNavigated' -Url 'http://localhost:8080/next'
            New-WebTestReply -Message $Message
            New-FbFrameEvent -Method 'Page.frameStoppedLoading' -AfterMs 50
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $script:FbGo } -Quads $script:FbGoQuads -Override $override)
        $result = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect (New-FbEffect)
        Assert-True $result.Navigated 'events before the reply belong to the step'
        Assert-StringEqual -Expected 'http://localhost:8080/next' -Actual ([string]$result.Url)
    }

    It 'waits for a navigation that starts 300 ms after the click' {
        $marks = @{ Released = [datetime]::MinValue }
        $clockRef = @{ Clock = $null }
        $override = New-FbMouseOverride -OnRelease {
            param($Message)
            $marks.Released = [datetime]$clockRef.Clock.Now
            New-WebTestReply -Message $Message
            New-FbFrameEvent -Method 'Page.frameStartedLoading' -AfterMs 300
            New-FbFrameEvent -Method 'Page.frameNavigated' -Url 'http://localhost:8080/later' -AfterMs 350
            New-FbFrameEvent -Method 'Page.frameStoppedLoading' -AfterMs 400
        }
        $clock = New-WebTestClock
        $clockRef.Clock = $clock
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $script:FbGo } -Quads $script:FbGoQuads -Override $override) -Clock $clock
        $result = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect (New-FbEffect)
        Assert-True $result.Navigated 'the late navigation was waited for'
        Assert-StringEqual -Expected 'http://localhost:8080/later' -Actual ([string]$result.Url)
        Assert-True (($t.Clock.Now - $marks.Released).TotalMilliseconds -ge 900) 'it returned after the stop at 400 ms and the quiet time'
    }

    It 'stops waiting for quiet after the cap when nothing loads' {
        $marks = @{ Start = [datetime]::MinValue }
        $clock = New-WebTestClock
        $override = New-FbMouseOverride -OnRelease {
            param($Message)
            New-WebTestReply -Message $Message
            for ($i = 1; $i -le 60; $i++) { New-FbFrameEvent -Method 'Page.frameScheduledNavigation' -AfterMs (200 * $i) }
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $script:FbGo } -Quads $script:FbGoQuads -Override $override) -Clock $clock
        $marks.Start = $t.Clock.Now
        $result = Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(30) -Effect (New-FbEffect)
        $elapsed = ($t.Clock.Now - $marks.Start).TotalMilliseconds
        Assert-True ($elapsed -ge 10000 -and $elapsed -le 10200) "returned at $elapsed ms: the settle cap"
        Assert-True $result.Navigated 'the page kept signaling'
    }

    It 'closes a window the click opened and fails as unsupported' {
        $override = New-FbMouseOverride -OnRelease {
            param($Message)
            New-WebTestReply -Message $Message
            [ordered]@{ method = 'Target.targetCreated'; params = @{ targetInfo = @{ targetId = 'P1'; type = 'page'; openerId = 'T1'; url = 'about:blank' } }; _afterMs = 10 }
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $script:FbGo } -Quads $script:FbGoQuads -Override $override)
        $effect = New-FbEffect
        $failure = Get-FbFailure { Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'popup' -Actual $failure.Detail
        $closes = Get-FbSent -Test $t -Method 'Target.closeTarget'
        Assert-StringEqual -Expected 'P1' -Actual (@($closes | ForEach-Object { [string]$_['params']['targetId'] }) -join ',')
        Assert-Equal -Expected 0 -Actual $t.Connection.Page.Popups.Count
    }

    It 'fails a click that starts a download as unsupported' {
        $override = New-FbMouseOverride -OnRelease {
            param($Message)
            New-WebTestReply -Message $Message
            [ordered]@{ method = 'Browser.downloadWillBegin'; params = @{ frameId = 'T1'; guid = 'g1'; url = 'http://localhost:8080/file.zip' }; _afterMs = 10 }
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $script:FbGo } -Quads $script:FbGoQuads -Override $override)
        $effect = New-FbEffect
        $failure = Get-FbFailure { Invoke-WebPageClick -Connection $t.Connection -Locator @{ role = 'button'; name = 'Go' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) -Effect $effect }
        Assert-StringEqual -Expected 'unsupported' -Actual $failure.Kind
        Assert-StringEqual -Expected 'download' -Actual $failure.Detail
        Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'both effect facts are true'
    }

    It 'passes an expectation on any of several matches' {
        $tree = New-FbTree -Nodes @(
            (New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Delete' -Backend 10)
            (New-WebTestAxNode -Id 'b2' -Role 'button' -Name 'Delete' -Backend 11)
        )
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $tree })
        $failure = Get-FbFailure { Invoke-WebPageExpect -Connection $t.Connection -Locator @{ role = 'button'; name = 'Delete' } -DeadlineUtc $t.Clock.Now.AddSeconds(5) }
        Assert-Null $failure 'two matches are no error here'
        Assert-Equal -Expected 0 -Actual (Get-FbInputCount -Test $t)
    }

    It 'waits for every match to go when gone is set' {
        $shrinking = {
            param($Message, $State, $Read)
            $null = $Message, $State
            $count = [Math]::Max(0, 3 - $Read)
            New-FbTree -Nodes @(for ($i = 1; $i -le $count; $i++) { New-WebTestAxNode -Id "b$i" -Role 'button' -Name 'Delete' -Backend (10 + $i) })
        }
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $shrinking })
        $failure = Get-FbFailure { Invoke-WebPageExpect -Connection $t.Connection -Locator @{ role = 'button'; name = 'Delete' } -Gone -DeadlineUtc $t.Clock.Now.AddSeconds(5) }
        Assert-Null $failure 'the matches went'
        Assert-Equal -Expected 3 -Actual (Get-FbSent -Test $t -Method 'Accessibility.getFullAXTree').Count -Because 'two, then one, then none'
    }

    It 'fails an expectation with the count it saw' {
        $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 'b1' -Role 'button' -Name 'Delete' -Backend 10))
        $t = New-WebTestConnection -Responder (New-WebTestPage -Ax @{ S1 = $tree })
        $failure = Get-FbFailure { Invoke-WebPageExpect -Connection $t.Connection -Locator @{ role = 'button'; name = 'Delete'; nth = 2 } -DeadlineUtc $t.Clock.Now.AddSeconds(1) }
        Assert-StringEqual -Expected 'expectation' -Actual $failure.Kind
        Assert-StringEqual -Expected 'found 1' -Actual $failure.Detail
        Assert-Equal -Expected 1 -Actual $failure.MatchCount
    }

    It 'fails an expectation on a page that stopped answering as page_lost' {
        $page = New-WebTestPage -Override @{ 'Accessibility.getFullAXTree' = { param($Message, $State) $null = $Message, $State } }
        $t = New-WebTestConnection -Responder $page
        $failure = Get-FbFailure { Invoke-WebPageExpect -Connection $t.Connection -Text 'Done' -DeadlineUtc $t.Clock.Now.AddSeconds(30) }
        Assert-StringEqual -Expected 'page_lost' -Actual $failure.Kind -Because 'not expectation'
        Assert-StringEqual -Expected 'no reply to Accessibility.getFullAXTree' -Actual $failure.Detail
    }

    It 'does not take an incomplete forest as proof that something is gone' {
        $tree = New-FbTree -Nodes @((New-WebTestAxNode -Id 'f1' -Role 'Iframe' -Backend 40))
        $page = New-WebTestPage -Ax @{ S1 = $tree } -Describe @{ 40 = @{ backendNodeId = 40; nodeName = 'IFRAME'; frameId = 'F9' } }
        $t = New-WebTestConnection -Responder $page
        $start = $t.Clock.Now
        $failure = Get-FbFailure { Invoke-WebPageExpect -Connection $t.Connection -Locator @{ role = 'button'; name = 'Delete' } -Gone -DeadlineUtc $start.AddSeconds(1) }
        Assert-NotNull $failure 'an unreadable frame may still hold the button'
        Assert-StringEqual -Expected 'expectation' -Actual $failure.Kind
        $mainReads = @((Get-FbSent -Test $t -Method 'Accessibility.getFullAXTree') | Where-Object { -not $_['params'].Contains('frameId') })
        Assert-True ($mainReads.Count -gt 5) 'it kept polling'
        Assert-True (($t.Clock.Now - $start).TotalMilliseconds -ge 900) 'until the deadline'
    }

    It 'ends a step whose socket closes as transport' {
        $page = New-WebTestPage -Override @{ 'Accessibility.getFullAXTree' = { param($Message, $State) $null = $Message, $State; 'close' } }
        $t = New-WebTestConnection -Responder $page
        $failure = Get-FbFailure { Invoke-WebPageExpect -Connection $t.Connection -Text 'Done' -DeadlineUtc $t.Clock.Now.AddSeconds(5) }
        Assert-StringEqual -Expected 'transport' -Actual $failure.Kind
    }

    It 'opens a crashed page again although the commit comes after the navigate reply' {
        $page = New-WebTestPage -Override @{
            'Page.navigate' = {
                param($Message, $State)
                $null = $State
                New-WebTestReply -Message $Message -Result @{ frameId = 'T1'; loaderId = 'L2' }
                New-FbFrameEvent -Method 'Page.frameNavigated' -Url 'http://localhost:8080/' -AfterMs 200
            }
        }
        $t = New-WebTestConnection -Responder $page
        Add-WebTestEvent -Transport $t.Transport -Event @{ method = 'Inspector.targetCrashed'; sessionId = 'S1'; params = @{} }
        $effect = New-FbEffect
        $result = $null
        $failure = Get-FbFailure { $script:FbOpenResult = Invoke-WebPageOpen -Connection $t.Connection -Url 'http://localhost:8080/' -DeadlineUtc $t.Clock.Now.AddSeconds(10) -Effect $effect }
        $result = $script:FbOpenResult
        Assert-Null $failure 'no page_lost for a page the navigate revived'
        Assert-True $result.Navigated 'the commit after the reply counts'
        Assert-False $t.Connection.Page.Crashed 'the page is usable again'
    }
}

Describe 'page verbs' {
    # Handler level: the session and protocol functions are mocked where the
    # handlers call them, so each case states the outcome of one call and reads
    # what the handler filed.
    BeforeAll {
        function New-VerbTestEntry {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory web session entry.')]
            param([AllowNull()][hashtable]$Cdp)
            $entry = New-WebTestSession -Connection $Cdp
            $entry.LocalPort = 4242
            return $entry
        }
    }
    BeforeEach {
        $script:VerbSeen = @{}
        $script:VerbConnection = @{ Live = $true; Name = 'live'; Page = @{ Url = 'http://localhost:8080/login' } }
        $script:VerbEntry = New-VerbTestEntry -Cdp $script:VerbConnection
        $script:VerbOpened = New-VerbTestEntry -Cdp $null
        $script:VerbFresh = @{ Live = $true; Name = 'fresh'; Page = @{ Url = 'about:blank' } }
        Mock Get-GuestWebSession -ModuleName Test.WebHandler { $script:VerbEntry }
        Mock Test-GuestWebSession -ModuleName Test.WebHandler { @{ Alive = $true; Code = ''; Detail = '' } }
        Mock Open-GuestWebSession -ModuleName Test.WebHandler { @{ Ok = $true; Session = $script:VerbOpened; Kind = ''; Code = ''; Detail = '' } }
        Mock Close-GuestWebSession -ModuleName Test.WebHandler { 1 }
        Mock Connect-WebCdp -ModuleName Test.WebHandler { $script:VerbFresh }
        Mock Open-WebCdpPage -ModuleName Test.WebHandler { }
        Mock Close-WebCdp -ModuleName Test.WebHandler { }
        Mock Test-WebCdpOpen -ModuleName Test.WebHandler { [bool]($null -ne $Connection -and $Connection.Live) }
        Mock Invoke-WebPageOpen -ModuleName Test.WebHandler { $script:VerbSeen.Open = @{ Url = $Url }; @{ Navigated = $false; Url = $Url } }
        Mock Invoke-WebPageClick -ModuleName Test.WebHandler { $script:VerbSeen.Click = @{ Locator = $Locator }; @{ Navigated = $false; Url = '' } }
        Mock Invoke-WebPageFill -ModuleName Test.WebHandler { $script:VerbSeen.Fill = @{ Locator = $Locator; Text = $Text }; @{ Navigated = $false; Url = '' } }
        Mock Invoke-WebPageSelect -ModuleName Test.WebHandler { $script:VerbSeen.Select = @{ Locator = $Locator; Option = $Option }; @{ Navigated = $false; Url = '' } }
        Mock Invoke-WebPagePress -ModuleName Test.WebHandler { $script:VerbSeen.Press = @{ Key = $Key }; @{ Navigated = $false; Url = '' } }
        Mock Invoke-WebPageExpect -ModuleName Test.WebHandler { $script:VerbSeen.Expect = @{ Locator = $Locator; Text = $Text }; @{ Navigated = $false; Url = '' } }
    }

    It 'registers seven verbs, each with a handler' {
        foreach ($verbName in 'webOpen', 'webClick', 'webFill', 'webSelect', 'webPress', 'webExpect', 'webClose') {
            Assert-True (Test-SequenceActionHasHandler -Name $verbName) "$verbName has a handler"
        }
    }

    It 'returns a strict boolean and files kind, locator, candidates and both effect facts' {
        Mock Invoke-WebPageClick -ModuleName Test.WebHandler {
            $Effect.Dispatched = $script:VerbDispatch
            $Effect.Acknowledged = $script:VerbAcknowledge
            throw (New-WebFailureException -Kind 'ambiguous' -Detail '2 matches' -MatchCount 2 `
                    -Candidates @(@{ role = 'button'; name = 'Go' }, @{ role = 'button'; name = 'Go' }))
        }
        $handler = (Get-SequenceAction -Name 'webClick').Handler
        $step = [ordered]@{ action = 'webClick'; role = 'button'; name = 'Go' }
        $script:VerbDispatch = $true
        $script:VerbAcknowledge = $false
        $result = & $handler (New-WebTestContext -Step $step)
        Assert-True ($result -is [bool]) 'the handler returns a strict boolean'
        Assert-False $result 'an ambiguous locator fails the step'
        $slot = (Get-SequenceFailureState).StepWebFailure
        Assert-StringEqual -Expected 'ambiguous' -Actual ([string]$slot.kind)
        Assert-StringEqual -Expected 'web_step_failed' -Actual ([string]$slot.failureClass)
        Assert-StringEqual -Expected 'webClick' -Actual ([string]$slot.verb)
        Assert-StringEqual -Expected 'button' -Actual ([string]$slot.locator.role)
        Assert-StringEqual -Expected 'Go' -Actual ([string]$slot.locator.name)
        Assert-Equal -Expected 2 -Actual @($slot.candidates).Count
        Assert-Equal -Expected 2 -Actual ([int]$slot.matchCount)
        Assert-StringEqual -Expected 'uncertain' -Actual ([string]$slot.effect) -Because 'dispatched without an acknowledgment'
        Assert-StringEqual -Expected 'http://localhost:8080/login' -Actual ([string]$slot.url)
        $script:VerbAcknowledge = $true
        $null = & $handler (New-WebTestContext -Step $step)
        Assert-StringEqual -Expected 'applied' -Actual ([string](Get-SequenceFailureState).StepWebFailure.effect) -Because 'dispatched and acknowledged'
        $script:VerbDispatch = $false
        $script:VerbAcknowledge = $false
        $null = & $handler (New-WebTestContext -Step $step)
        Assert-StringEqual -Expected 'none-proven' -Actual ([string](Get-SequenceFailureState).StepWebFailure.effect) -Because 'nothing dispatched'
    }

    It 'refuses <Case> as invalid_step before any command' -ForEach @(
        @{ Case = 'css with role'; PageStep = @{ action = 'webClick'; css = '#go'; role = 'button' }; Blank = $false; NoSession = $false; Detail = '' }
        @{ Case = 'an empty expanded name'; PageStep = @{ action = 'webClick'; role = 'button'; name = '{blank}' }; Blank = $true; NoSession = $false; Detail = '' }
        @{ Case = 'nth 0'; PageStep = @{ action = 'webClick'; role = 'button'; name = 'Go'; nth = 0 }; Blank = $false; NoSession = $false; Detail = '' }
        @{ Case = 'a page verb with no session'; PageStep = @{ action = 'webPress'; key = 'Enter' }; Blank = $false; NoSession = $true; Detail = 'no page open' }
        @{ Case = 'text with role on webExpect'; PageStep = @{ action = 'webExpect'; text = 'Done'; role = 'heading' }; Blank = $false; NoSession = $false; Detail = '' }
        @{ Case = 'text with nth on webExpect'; PageStep = @{ action = 'webExpect'; text = 'Done'; nth = 2 }; Blank = $false; NoSession = $false; Detail = '' }
    ) {
        if ($NoSession) { $script:VerbEntry = $null }
        $expand = if ($Blank) { { param($Value) if ([string]$Value -ceq '{blank}') { '' } else { $Value } } } else { { param($Value) $Value } }
        $result = & (Get-SequenceAction -Name $PageStep.action).Handler (New-WebTestContext -Step $PageStep -ExpandVariable $expand)
        Assert-True ($result -is [bool] -and -not $result) "$Case fails the step"
        $slot = (Get-SequenceFailureState).StepWebFailure
        Assert-StringEqual -Expected 'invalid_step' -Actual ([string]$slot.kind)
        Assert-StringEqual -Expected 'plan_invalid' -Actual ([string]$slot.failureClass)
        Assert-StringEqual -Expected 'none-proven' -Actual ([string]$slot.effect)
        if ($Detail) { Assert-StringEqual -Expected $Detail -Actual ([string]$slot.detail) }
        foreach ($operation in 'Invoke-WebPageOpen', 'Invoke-WebPageClick', 'Invoke-WebPageFill', 'Invoke-WebPageSelect', 'Invoke-WebPagePress', 'Invoke-WebPageExpect', 'Connect-WebCdp', 'Open-GuestWebSession') {
            Should -Invoke $operation -ModuleName Test.WebHandler -Times 0 -Exactly
        }
    }

    It 'opens only http and https URLs and about:blank' {
        $handler = (Get-SequenceAction -Name 'webOpen').Handler
        foreach ($openUrl in 'file:///etc/hostname', 'chrome://version/', 'not a url') {
            $result = & $handler (New-WebTestContext -Step @{ action = 'webOpen'; url = $openUrl })
            Assert-False $result "$openUrl is refused"
            $slot = (Get-SequenceFailureState).StepWebFailure
            Assert-StringEqual -Expected 'invalid_step' -Actual ([string]$slot.kind) -Because $openUrl
            Assert-StringEqual -Expected 'url' -Actual ([string]$slot.detail) -Because $openUrl
        }
        Should -Invoke Open-GuestWebSession -ModuleName Test.WebHandler -Times 0 -Exactly
        Should -Invoke Invoke-WebPageOpen -ModuleName Test.WebHandler -Times 0 -Exactly
        foreach ($openUrl in 'about:blank', 'http://localhost:8080/', 'https://localhost:8443/x') {
            Assert-True (& $handler (New-WebTestContext -Step @{ action = 'webOpen'; url = $openUrl })) "$openUrl is opened"
        }
        Should -Invoke Invoke-WebPageOpen -ModuleName Test.WebHandler -Times 3 -Exactly
    }

    It 'opens a session when there is none or it is dead, and reuses a live one' {
        $handler = (Get-SequenceAction -Name 'webOpen').Handler
        $step = @{ action = 'webOpen'; url = 'http://localhost:8080/' }
        $script:VerbEntry = $null
        Assert-True (& $handler (New-WebTestContext -Step $step)) 'the first open passes'
        Should -Invoke Open-GuestWebSession -ModuleName Test.WebHandler -Times 1 -Exactly -ParameterFilter { $OwnerId -ceq 'seq' -and $VMName -ceq 'fixture-vm' }
        Should -Invoke Connect-WebCdp -ModuleName Test.WebHandler -Times 1 -Exactly
        Assert-True ([object]::ReferenceEquals($script:VerbOpened.Cdp, $script:VerbFresh)) 'the new session keeps its connection'

        $script:VerbEntry = New-VerbTestEntry -Cdp @{ Live = $true; Name = 'kept'; Page = @{ Url = '' } }
        Assert-True (& $handler (New-WebTestContext -Step $step)) 'a live session is reused'
        Should -Invoke Open-GuestWebSession -ModuleName Test.WebHandler -Times 1 -Exactly
        Should -Invoke Connect-WebCdp -ModuleName Test.WebHandler -Times 1 -Exactly

        Mock Test-GuestWebSession -ModuleName Test.WebHandler { @{ Alive = $false; Code = 'tunnel-exited'; Detail = '' } }
        Assert-True (& $handler (New-WebTestContext -Step $step)) 'a dead session is opened again'
        Should -Invoke Open-GuestWebSession -ModuleName Test.WebHandler -Times 2 -Exactly
    }

    It 'connects again on a live session whose page connection is gone' {
        $old = @{ Live = $false; Name = 'old'; Page = $null }
        $script:VerbEntry = New-VerbTestEntry -Cdp $old
        $result = & (Get-SequenceAction -Name 'webOpen').Handler (New-WebTestContext -Step @{ action = 'webOpen'; url = 'http://localhost:8080/' })
        Assert-True $result 'the open passes on a new connection'
        Should -Invoke Close-WebCdp -ModuleName Test.WebHandler -Times 1 -Exactly -ParameterFilter { $Connection.Name -ceq 'old' }
        Should -Invoke Connect-WebCdp -ModuleName Test.WebHandler -Times 1 -Exactly -ParameterFilter { $Port -eq 4242 }
        Should -Invoke Open-WebCdpPage -ModuleName Test.WebHandler -Times 1 -Exactly
        Should -Invoke Open-GuestWebSession -ModuleName Test.WebHandler -Times 0 -Exactly
        Assert-StringEqual -Expected 'fresh' -Actual ([string]$script:VerbEntry.Cdp.Name)
    }

    It 'keeps a connection whose page could not be opened where the session close finds it' {
        $script:VerbEntry = New-VerbTestEntry -Cdp $null
        Mock Open-WebCdpPage -ModuleName Test.WebHandler { throw (New-WebFailureException -Kind 'protocol' -Detail 'Page.enable: -32601 not found') }
        $result = & (Get-SequenceAction -Name 'webOpen').Handler (New-WebTestContext -Step @{ action = 'webOpen'; url = 'http://localhost:8080/' })
        Assert-True ($result -is [bool] -and -not $result) 'the open fails'
        Assert-StringEqual -Expected 'protocol' -Actual ([string](Get-SequenceFailureState).StepWebFailure.kind)
        Assert-True ([object]::ReferenceEquals($script:VerbEntry.Cdp, $script:VerbFresh)) 'the entry keeps the connection Connect-WebCdp returned'
        Should -Invoke Invoke-WebPageOpen -ModuleName Test.WebHandler -Times 0 -Exactly
    }

    It 'files the session failure the launcher reported' {
        $script:VerbEntry = $null
        Mock Open-GuestWebSession -ModuleName Test.WebHandler {
            $Effect['Dispatched'] = $true
            @{ Ok = $false; Session = $null; Kind = 'browser_unavailable'; Code = 'launcher-refused'; Detail = 'browser-not-found: x' }
        }
        $result = & (Get-SequenceAction -Name 'webOpen').Handler (New-WebTestContext -Step @{ action = 'webOpen'; url = 'http://localhost:8080/' })
        Assert-False $result 'the open fails'
        $slot = (Get-SequenceFailureState).StepWebFailure
        Assert-StringEqual -Expected 'browser_unavailable' -Actual ([string]$slot.kind)
        Assert-StringEqual -Expected 'browser-not-found: x' -Actual ([string]$slot.detail)
        Assert-StringEqual -Expected 'uncertain' -Actual ([string]$slot.effect) -Because 'the launcher may have started a browser'
    }

    It 'lets an error it does not own leave the handler, and a stopped pipeline too' {
        $handler = (Get-SequenceAction -Name 'webClick').Handler
        $step = @{ action = 'webClick'; role = 'button'; name = 'Go' }
        Mock Invoke-WebPageClick -ModuleName Test.WebHandler { throw 'fixture: not a page failure' }
        Assert-Throw { & $handler (New-WebTestContext -Step $step) } -Match 'fixture: not a page failure' -Because 'an error that is not a page failure leaves the handler'
        Assert-Null (Get-SequenceFailureState).StepWebFailure 'nothing is filed for it'
        Mock Invoke-WebPageClick -ModuleName Test.WebHandler { throw [System.Management.Automation.PipelineStoppedException]::new() }
        # A script cannot catch a pipeline stop, so the handler runs in a
        # nested pipeline of this runspace (the mocks still apply), whose end
        # the case reads.
        $nested = [powershell]::Create([System.Management.Automation.RunspaceMode]::CurrentRunspace)
        try {
            $null = $nested.AddScript('param($Handler, $Context) & $Handler $Context').AddArgument($handler).AddArgument((New-WebTestContext -Step $step))
            $output = @($nested.Invoke())
            $state = $nested.InvocationStateInfo
        } finally {
            $nested.Dispose()
        }
        Assert-Equal -Expected 0 -Actual $output.Count -Because 'the handler returns nothing for a stopped pipeline'
        Assert-StringEqual -Expected 'Stopped' -Actual ([string]$state.State) -Because 'the stop reaches the pipeline that ran the handler'
        $stopped = $state.Reason
        while ($null -ne $stopped -and $stopped -isnot [System.Management.Automation.PipelineStoppedException]) { $stopped = $stopped.InnerException }
        Assert-NotNull $stopped 'a stopped pipeline leaves the handler'
        Assert-Null (Get-SequenceFailureState).StepWebFailure 'nothing is filed for a stopped pipeline'
    }

    It 'ends the session when the transport fails and names an exited browser' {
        $handler = (Get-SequenceAction -Name 'webExpect').Handler
        $step = @{ action = 'webExpect'; text = 'Done' }
        Mock Invoke-WebPageExpect -ModuleName Test.WebHandler { throw (New-WebFailureException -Kind 'transport' -Detail 'socket closed') }
        Assert-False (& $handler (New-WebTestContext -Step $step)) 'the step fails'
        $slot = (Get-SequenceFailureState).StepWebFailure
        Assert-StringEqual -Expected 'transport' -Actual ([string]$slot.kind)
        Assert-StringEqual -Expected 'network_timeout' -Actual ([string]$slot.failureClass)
        Assert-StringEqual -Expected 'socket closed' -Actual ([string]$slot.detail)
        Should -Invoke Close-GuestWebSession -ModuleName Test.WebHandler -Times 1 -Exactly -ParameterFilter { $Reason -ceq 'web-transport' -and $VMName -ceq 'fixture-vm' }
        Mock Test-GuestWebSession -ModuleName Test.WebHandler { @{ Alive = $false; Code = 'browser-exited'; Detail = 'exit 70' } }
        Assert-False (& $handler (New-WebTestContext -Step $step)) 'the step fails again'
        Assert-True ([string](Get-SequenceFailureState).StepWebFailure.detail).StartsWith('browser exited: ', [StringComparison]::Ordinal) 'the detail names the exited browser'
    }

    It 'shows no typed text in the label, the debug stream or the failure of a sensitive fill' {
        $secret = 'fixture-secret-7'
        $script:DebugLines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Debug -ModuleName Test.WebHandler { $script:DebugLines.Add([string]$Message) }
        Mock Invoke-WebPageFill -ModuleName Test.WebHandler {
            $Effect.Dispatched = $true
            $Effect.Acknowledged = $true
            throw (New-WebFailureException -Kind 'expectation' -Detail "value differs: wanted $($Text.Length) characters, read 3")
        }
        $step = [ordered]@{ action = 'webFill'; role = 'textbox'; name = 'Password'; text = $secret; sensitive = $true }
        $context = New-WebTestContext -Step $step
        Assert-False (& (Get-SequenceAction -Name 'webFill').Handler $context) 'the fill fails'
        $fillLines = @($script:DebugLines | Where-Object { $_ -match 'webFill' })
        Assert-Equal -Expected 1 -Actual $fillLines.Count -Because 'the fill writes one debug line'
        Assert-Match -Pattern '\*\*\*' -Actual $fillLines[0]
        foreach ($line in $script:DebugLines) { Assert-False $line.Contains($secret) "the debug line '$line' holds no typed text" }
        $label = Get-SequenceActionFailureLabel -Step $step -Vars @{} -ExpandVariable $context.ExpandVariable -VMName 'fixture-vm' -GuestKey 'guest.ubuntu.server.26'
        Assert-False ([string]$label).Contains($secret) "the label '$label' holds no typed text"
        $slotJson = (Get-SequenceFailureState).StepWebFailure | ConvertTo-Json -Depth 12
        Assert-Match -Pattern 'value differs' -Actual $slotJson
        Assert-False $slotJson.Contains($secret) 'the failure account holds no typed text'
    }

    It 'passes webClose when no page is open' {
        $script:VerbEntry = $null
        $result = & (Get-SequenceAction -Name 'webClose').Handler (New-WebTestContext -Step @{ action = 'webClose' })
        Assert-True ($result -is [bool] -and $result) 'webClose without a page passes'
        Should -Invoke Close-GuestWebSession -ModuleName Test.WebHandler -Times 0 -Exactly
    }

    It 'closes the session on webClose' {
        $result = & (Get-SequenceAction -Name 'webClose').Handler (New-WebTestContext -Step @{ action = 'webClose' })
        Assert-True ($result -is [bool] -and $result) 'webClose passes'
        Should -Invoke Close-GuestWebSession -ModuleName Test.WebHandler -Times 1 -Exactly -ParameterFilter { $Reason -ceq 'web-close' -and $VMName -ceq 'fixture-vm' }
    }

    It 'expands name, css, url, text and option, and leaves role, match, nth and key literal' {
        $expand = { param($Value) if ($Value -is [string]) { $Value.Replace('{v}', 'X') } else { $Value } }
        $run = { param($PageStep) & (Get-SequenceAction -Name $PageStep.action).Handler (New-WebTestContext -Step $PageStep -ExpandVariable $expand) }
        Assert-True (& $run @{ action = 'webClick'; role = 'b{v}'; name = 'n{v}'; match = 'contains'; nth = '2' }) 'the click passes'
        $locator = $script:VerbSeen.Click.Locator
        Assert-StringEqual -Expected 'b{v}' -Actual ([string]$locator['role'])
        Assert-StringEqual -Expected 'nX' -Actual ([string]$locator['name'])
        Assert-StringEqual -Expected 'contains' -Actual ([string]$locator['match'])
        Assert-True ($locator['nth'] -is [int] -and $locator['nth'] -eq 2) 'nth is taken as written, as an integer'
        Assert-True (& $run @{ action = 'webClick'; css = 'c{v}' }) 'the css click passes'
        Assert-StringEqual -Expected 'cX' -Actual ([string]$script:VerbSeen.Click.Locator['css'])
        Assert-True (& $run @{ action = 'webOpen'; url = 'http://h{v}.test/' }) 'the open passes'
        Assert-StringEqual -Expected 'http://hX.test/' -Actual ([string]$script:VerbSeen.Open.Url)
        Assert-True (& $run @{ action = 'webExpect'; text = 't{v}' }) 'the expectation passes'
        Assert-StringEqual -Expected 'tX' -Actual ([string]$script:VerbSeen.Expect.Text)
        Assert-True (& $run @{ action = 'webSelect'; role = 'combobox'; name = 's{v}'; option = 'o{v}' }) 'the select passes'
        Assert-StringEqual -Expected 'oX' -Actual ([string]$script:VerbSeen.Select.Option)
        Assert-StringEqual -Expected 'sX' -Actual ([string]$script:VerbSeen.Select.Locator['name'])
        Assert-True (& $run @{ action = 'webFill'; role = 'textbox'; name = 'Name'; text = 'f{v}' }) 'the fill passes'
        Assert-StringEqual -Expected 'fX' -Actual ([string]$script:VerbSeen.Fill.Text)
        Assert-True (& $run @{ action = 'webPress'; key = 'Enter{v}' }) 'the press passes'
        Assert-StringEqual -Expected 'Enter{v}' -Actual ([string]$script:VerbSeen.Press.Key)
    }
}

Describe 'the sequence schema types the page verbs' {
    # The page branches are the one check of a page step's fields before it
    # runs, so each form a handler refuses is also a schema violation.
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/sequence.schema.yml'
        $script:PageSchemaJson = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        function ConvertTo-PageSequenceJson {
            param([System.Collections.IDictionary]$PageStep)
            return ([ordered]@{
                    description = 'schema probe'; keystrokeMechanism = 'ssh'
                    resource    = [ordered]@{ 'ubuntu.server.26' = @('start.guest.ubuntu.server.26') }
                    component   = @($PageStep)
                } | ConvertTo-Json -Depth 32)
        }
    }

    It 'accepts a webClick by role and name and by css alone, and a webExpect by text' {
        foreach ($accepted in @(
                [ordered]@{ action = 'webClick'; role = 'button'; name = 'Sign in' },
                [ordered]@{ action = 'webClick'; css = '#go' },
                [ordered]@{ action = 'webExpect'; text = 'Welcome' })) {
            Assert-True (Test-Json -Json (ConvertTo-PageSequenceJson -PageStep $accepted) -Schema $script:PageSchemaJson -ErrorAction SilentlyContinue) `
                "the schema accepts $($accepted | ConvertTo-Json -Compress)"
        }
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'role without name'; PageStep = [ordered]@{ action = 'webClick'; role = 'button' } }
        @{ Case = 'css with role'; PageStep = [ordered]@{ action = 'webClick'; css = '#go'; role = 'button' } }
        @{ Case = 'nth 0'; PageStep = [ordered]@{ action = 'webClick'; role = 'button'; name = 'Go'; nth = 0 } }
        @{ Case = 'match fuzzy'; PageStep = [ordered]@{ action = 'webClick'; role = 'button'; name = 'Go'; match = 'fuzzy' } }
        @{ Case = 'a webPress key Home'; PageStep = [ordered]@{ action = 'webPress'; key = 'Home' } }
        @{ Case = 'a webFill without text'; PageStep = [ordered]@{ action = 'webFill'; role = 'textbox'; name = 'Name' } }
        @{ Case = 'a webExpect with text and css'; PageStep = [ordered]@{ action = 'webExpect'; text = 'Done'; css = '#done' } }
        @{ Case = 'a webExpect with text and nth'; PageStep = [ordered]@{ action = 'webExpect'; text = 'Done'; nth = 1 } }
    ) {
        Assert-False (Test-Json -Json (ConvertTo-PageSequenceJson -PageStep $PageStep) -Schema $script:PageSchemaJson -ErrorAction SilentlyContinue) `
            "the schema rejects $Case"
    }
}

Describe 'the page snapshot entries' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.WorkloadProtocol.psm1') -Force -Global -DisableNameChecking
        # A forest read from hand-built accessibility nodes over the scripted
        # transport, so ignored nodes and frames reach the entries as a page gives them.
        function Get-SnapshotTestForest {
            param(
                [Parameter(Mandatory)][hashtable]$Ax,
                [hashtable]$Describe = @{},
                [hashtable]$Children = @{}
            )
            $t = New-WebTestConnection -Responder (New-WebTestPage -Ax $Ax -Describe $Describe)
            foreach ($frameId in @($Children.Keys)) {
                $t.Connection.Page.Children[$frameId] = @{ SessionId = $Children[$frameId]; ParentSessionId = 'S1'; AutoAttach = $true }
            }
            return (Read-WebPageForest -Connection $t.Connection -DeadlineUtc ([datetime]$t.Clock.Now).AddSeconds(30))
        }
    }

    It 'shows roles, names, tags and nesting and hides unnamed wrappers' {
        $nodes = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'Sign in' -Children 2 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role main -Name '' -Children 3, 4 -Backend 2),
            (New-WebTestAxNode -Id 3 -Role heading -Name 'Sign in' -Children 31 -Backend 3 -Props @{ level = 1 }),
            (New-WebTestAxNode -Id 31 -Role StaticText -Name 'Sign in' -Backend 31),
            (New-WebTestAxNode -Id 4 -Role form -Name '' -Children 5, 10 -Backend 4),
            (New-WebTestAxNode -Id 5 -Role generic -Name '' -Children 6, 7, 8, 9 -Backend 5),
            (New-WebTestAxNode -Id 6 -Role textbox -Name 'User name' -Children 61 -Backend 6 -Value 'maria' -Props @{ editable = 'plaintext' }),
            (New-WebTestAxNode -Id 61 -Role StaticText -Name 'maria' -Backend 61),
            (New-WebTestAxNode -Id 7 -Role textbox -Name 'Password' -Backend 7 -Props @{ editable = 'plaintext' }),
            (New-WebTestAxNode -Id 8 -Role checkbox -Name 'Remember me' -Backend 8 -Props @{ checked = 'false' }),
            (New-WebTestAxNode -Id 9 -Role button -Name 'Sign in' -Children 91 -Backend 9 -Props @{ disabled = $true }),
            (New-WebTestAxNode -Id 91 -Role StaticText -Name 'Sign in' -Backend 91),
            (New-WebTestAxNode -Id 10 -Role generic -Name 'hidden note' -Backend 10 -Ignored)
        )
        $expected = @'
- main [ref=p1]
  - heading "Sign in" [level=1] [ref=p2]
  - form [ref=p3]
    - textbox "User name" [value="maria"] [ref=p4]
    - textbox "Password" [ref=p5]
    - checkbox "Remember me" [checked=false] [ref=p6]
    - button "Sign in" [disabled=true] [ref=p7]
'@
        $entries = Get-WebPageSnapshotEntry -Forest (Get-SnapshotTestForest -Ax @{ S1 = $nodes })
        $snapshot = ConvertTo-WorkloadPageSnapshot -Entry $entries -Url 'http://localhost/login' -Title 'Sign in' -Generation 1 -Ordinal 1 -ReferenceBase 0 -Find ''
        $actualLines = [System.Collections.Generic.List[string]]($snapshot.FileText -split '\r?\n')
        $actualLines.RemoveAt(0)
        if ($actualLines.Count -gt 0 -and $actualLines[$actualLines.Count - 1] -eq '') { $actualLines.RemoveAt($actualLines.Count - 1) }
        $expectedLines = [System.Collections.Generic.List[string]]($expected -split '\r?\n')
        if ($expectedLines.Count -gt 0 -and $expectedLines[$expectedLines.Count - 1] -eq '') { $expectedLines.RemoveAt($expectedLines.Count - 1) }
        Assert-Equal -Expected $expectedLines.Count -Actual $actualLines.Count -Because ("the snapshot reads:`n" + ($actualLines -join "`n"))
        for ($i = 0; $i -lt $expectedLines.Count; $i++) {
            Assert-StringEqual -Expected $expectedLines[$i] -Actual $actualLines[$i]
        }
    }

    It 'merges text runs and leaves out text its parent already names' {
        $inline = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'T' -Children 2 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role main -Name '' -Children 3 -Backend 2),
            (New-WebTestAxNode -Id 3 -Role paragraph -Name '' -Children 4, 5, 7 -Backend 3),
            (New-WebTestAxNode -Id 4 -Role StaticText -Name 'Wel' -Backend 4),
            (New-WebTestAxNode -Id 5 -Role mark -Name '' -Children 6 -Backend 5),
            (New-WebTestAxNode -Id 6 -Role StaticText -Name 'come' -Backend 6),
            (New-WebTestAxNode -Id 7 -Role StaticText -Name ' aboard' -Backend 7)
        )
        # The function returns its entries as one array: assign it, then filter.
        $entries = Get-WebPageSnapshotEntry -Forest (Get-SnapshotTestForest -Ax @{ S1 = $inline })
        $texts = @($entries | Where-Object { $_.Kind -ceq 'text' })
        Assert-Equal -Expected 1 -Actual $texts.Count
        Assert-StringEqual -Expected 'Welcome aboard' -Actual ([string]$texts[0].Name)

        $blocks = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'T' -Children 2 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role main -Name '' -Children 3, 5 -Backend 2),
            (New-WebTestAxNode -Id 3 -Role paragraph -Name '' -Children 4 -Backend 3),
            (New-WebTestAxNode -Id 4 -Role StaticText -Name 'Block A' -Backend 4),
            (New-WebTestAxNode -Id 5 -Role paragraph -Name '' -Children 6 -Backend 5),
            (New-WebTestAxNode -Id 6 -Role StaticText -Name 'Block B' -Backend 6)
        )
        $entries = Get-WebPageSnapshotEntry -Forest (Get-SnapshotTestForest -Ax @{ S1 = $blocks })
        $main = @($entries | Where-Object { $_.Role -ceq 'main' })[0]
        $texts = @($entries | Where-Object { $_.Kind -ceq 'text' })
        Assert-Equal -Expected 1 -Actual $texts.Count
        Assert-StringEqual -Expected 'Block A Block B' -Actual ([string]$texts[0].Name)
        Assert-Equal -Expected ([int]$main.Indent + 1) -Actual ([int]$texts[0].Indent)

        $named = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'T' -Children 2 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role heading -Name 'Sign in' -Children 3 -Backend 2 -Props @{ level = 2 }),
            (New-WebTestAxNode -Id 3 -Role StaticText -Name 'Sign in' -Backend 3)
        )
        $entries = Get-WebPageSnapshotEntry -Forest (Get-SnapshotTestForest -Ax @{ S1 = $named })
        Assert-Equal -Expected 0 -Actual @($entries | Where-Object { $_.Kind -ceq 'text' }).Count -Because 'the heading already names its text'
        Assert-Equal -Expected 1 -Actual $entries.Count
    }

    It 'gives an address only to entries with a DOM node' {
        $nodes = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'T' -Children 2, 3, 4 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role button -Name 'With node' -Backend 5),
            (New-WebTestAxNode -Id 3 -Role button -Name 'Without node'),
            (New-WebTestAxNode -Id 4 -Role paragraph -Name '' -Children 5 -Backend 7),
            (New-WebTestAxNode -Id 5 -Role StaticText -Name 'Some text' -Backend 8)
        )
        $entries = Get-WebPageSnapshotEntry -Forest (Get-SnapshotTestForest -Ax @{ S1 = $nodes })
        $with = @($entries | Where-Object { $_.Name -ceq 'With node' })[0]
        $without = @($entries | Where-Object { $_.Name -ceq 'Without node' })[0]
        $text = @($entries | Where-Object { $_.Kind -ceq 'text' })[0]
        Assert-Equal -Expected 5 -Actual ([int]$with.Address.BackendNodeId)
        Assert-StringEqual -Expected 'S1' -Actual ([string]$with.Address.SessionId)
        Assert-Null $without.Address 'an entry without a DOM node has no address'
        Assert-Null $text.Address 'a text entry has no address'
    }

    It 'shows a field value as a tag and nothing from inside a text control' {
        $long = 'y' * 100
        $nodes = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'T' -Children 2, 4, 5 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role textbox -Name 'Name' -Children 3 -Backend 2 -Value 'Ann "A" \ x' -Props @{ editable = 'plaintext' }),
            (New-WebTestAxNode -Id 3 -Role StaticText -Name 'Ann "A" \ x' -Backend 3),
            (New-WebTestAxNode -Id 4 -Role combobox -Name 'Color' -Backend 4 -Value 'Red'),
            (New-WebTestAxNode -Id 5 -Role textbox -Name 'Long' -Backend 5 -Value $long -Props @{ editable = 'plaintext' })
        )
        $entries = Get-WebPageSnapshotEntry -Forest (Get-SnapshotTestForest -Ax @{ S1 = $nodes })
        Assert-Equal -Expected 0 -Actual @($entries | Where-Object { $_.Kind -ceq 'text' }).Count -Because 'text inside a field is its value, not page text'
        $byName = @{}
        foreach ($entry in $entries) { $byName[[string]$entry.Name] = $entry }
        Assert-StringEqual -Expected 'value="Ann \"A\" \\ x"' -Actual (@($byName['Name'].Tags)[0])
        Assert-StringEqual -Expected 'value="Red"' -Actual (@($byName['Color'].Tags)[0])
        Assert-StringEqual -Expected ('value="' + ('y' * 80) + '"') -Actual (@($byName['Long'].Tags)[0])
    }

    It 'shows the content of a frame under its frame entry' {
        $page = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'Outer' -Children 2, 3 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role button -Name 'Outer action' -Backend 2),
            (New-WebTestAxNode -Id 3 -Role Iframe -Name '' -Backend 3)
        )
        $frame = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'Inner' -Children 2 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role button -Name 'Inner action' -Backend 7)
        )
        $forest = Get-SnapshotTestForest -Ax @{ S1 = $page; S2 = $frame } `
            -Describe @{ 3 = @{ backendNodeId = 3; nodeName = 'IFRAME'; frameId = 'F2'; attributes = @() } } -Children @{ F2 = 'S2' }
        $entries = Get-WebPageSnapshotEntry -Forest $forest
        $nodesShown = @($entries | Where-Object { $_.Kind -ceq 'node' })
        Assert-Equal -Expected 3 -Actual $nodesShown.Count
        Assert-StringEqual -Expected 'button|Outer action|0' -Actual ('{0}|{1}|{2}' -f $nodesShown[0].Role, $nodesShown[0].Name, $nodesShown[0].Indent)
        Assert-StringEqual -Expected 'Iframe' -Actual ([string]$nodesShown[1].Role)
        Assert-StringEqual -Expected 'button|Inner action' -Actual ('{0}|{1}' -f $nodesShown[2].Role, $nodesShown[2].Name)
        Assert-Equal -Expected ([int]$nodesShown[1].Indent + 1) -Actual ([int]$nodesShown[2].Indent) -Because 'the frame content stands one level below its frame entry'
        Assert-StringEqual -Expected 'S2' -Actual ([string]$nodesShown[2].Address.SessionId)
        Assert-Equal -Expected 7 -Actual ([int]$nodesShown[2].Address.BackendNodeId)
    }
}

Describe 'a page step files how it ended' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.WarmResume.psm1') -Force -Global -DisableNameChecking
        $script:GoPage = @(
            (New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'Page' -Children 2 -Backend 1),
            (New-WebTestAxNode -Id 2 -Role button -Name 'Go' -Backend 10)
        )
        $script:GoQuads = @{ 10 = @(100, 100, 140, 100, 140, 120, 100, 120) }

        # One row of the failure table: the page the row states, a session
        # over it (or none) and the handler run once with a real-clock deadline.
        function Invoke-PageFailureRow {
            param([Parameter(Mandatory)][string]$Situation)
            $root = New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'Page' -Children 2 -Backend 1
            $page = @{ Ax = @{ S1 = $script:GoPage }; Quads = $script:GoQuads; Partial = @{}; Override = @{} }
            $click = [ordered]@{ action = 'webClick'; role = 'button'; name = 'Go' }
            $expectDone = [ordered]@{ action = 'webExpect'; text = 'Done' }
            $openStep = [ordered]@{ action = 'webOpen'; url = 'http://localhost:8080/' }
            $mouse = {
                param($Message, $State)
                $null = $State
                if ([string]$Message['params']['type'] -ceq 'mouseReleased') { return (& $script:ReleaseAnswer $Message) }
                return (New-WebTestReply -Message $Message)
            }
            $script:ReleaseAnswer = { param($Message) New-WebTestReply -Message $Message }
            $noEntry = $false
            $preEvent = $null
            switch ($Situation) {
                'nothing matches' {
                    $page.Ax = @{ S1 = @($root, (New-WebTestAxNode -Id 2 -Role button -Name 'Stop' -Backend 11)) }
                    $step = $click; $step.timeoutSeconds = 1
                }
                'no option has the label' {
                    $page.Ax = @{ S1 = @($root, (New-WebTestAxNode -Id 2 -Role combobox -Name 'Color' -Backend 20)) }
                    $page.Quads = @{ 20 = @(10, 10, 90, 10, 90, 30, 10, 30) }
                    $page.Override['DOM.resolveNode'] = { param($Message) New-WebTestReply -Message $Message -Result @{ object = @{ objectId = 'obj-1' } } }
                    $page.Override['Runtime.callFunctionOn'] = {
                        param($Message)
                        New-WebTestReply -Message $Message -Result @{ result = @{ type = 'object'; value = @{ ok = $false; reason = 'no-option'; options = @('Red'); count = 1 } } }
                    }
                    $step = [ordered]@{ action = 'webSelect'; role = 'combobox'; name = 'Color'; option = 'Blue'; timeoutSeconds = 1 }
                }
                'two elements match' {
                    $page.Ax = @{ S1 = @((New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'Page' -Children 2, 3 -Backend 1),
                            (New-WebTestAxNode -Id 2 -Role button -Name 'Go' -Backend 10), (New-WebTestAxNode -Id 3 -Role button -Name 'Go' -Backend 11)) }
                    $step = $click
                }
                'the element stays disabled' {
                    $page.Ax = @{ S1 = @($root, (New-WebTestAxNode -Id 2 -Role button -Name 'Go' -Backend 10 -Props @{ disabled = $true })) }
                    $step = $click; $step.timeoutSeconds = 1
                }
                'a text never shows' {
                    $page.Ax = @{ S1 = @($root, (New-WebTestAxNode -Id 2 -Role StaticText -Name 'Waiting' -Backend 2)) }
                    $step = $expectDone; $step.timeoutSeconds = 1
                }
                'a filled value reads back changed' {
                    $page.Ax = @{ S1 = @($root, (New-WebTestAxNode -Id 2 -Role textbox -Name 'Name' -Backend 30 -Props @{ editable = 'plaintext' })) }
                    $page.Quads = @{ 30 = @(10, 10, 90, 10, 90, 30, 10, 30) }
                    $page.Partial = @{ 30 = (New-WebTestAxNode -Id 2 -Role textbox -Name 'Name' -Backend 30 -Value 'abcde' -Props @{ editable = 'plaintext' }) }
                    $step = [ordered]@{ action = 'webFill'; role = 'textbox'; name = 'Name'; text = 'abcdefghi' }
                }
                'a navigation fails' {
                    $page.Override['Page.navigate'] = { param($Message) New-WebTestReply -Message $Message -Result @{ frameId = 'T1'; loaderId = 'L1'; errorText = 'net::ERR_CONNECTION_REFUSED' } }
                    $step = $openStep
                }
                'the browser refuses the URL' {
                    $page.Override['Page.navigate'] = { param($Message) New-WebTestError -Message $Message -Code -32000 -Text 'Cannot navigate to invalid URL' }
                    $step = $openStep
                }
                'a dialog opens' {
                    $page.Override['Input.dispatchMouseEvent'] = $mouse
                    $script:ReleaseAnswer = { param($Message) $null = $Message; @{ method = 'Page.javascriptDialogOpening'; sessionId = 'S1'; params = @{ type = 'alert'; message = 'hello'; url = 'http://localhost:8080/' } } }
                    $step = $click
                }
                'the page opens a window' {
                    $page.Override['Input.dispatchMouseEvent'] = $mouse
                    $script:ReleaseAnswer = {
                        param($Message)
                        (New-WebTestReply -Message $Message)
                        @{ method = 'Target.targetCreated'; params = @{ targetInfo = @{ targetId = 'P9'; type = 'page'; openerId = 'T1'; url = 'about:blank' } }; _afterMs = 10 }
                    }
                    $step = $click
                }
                'a download begins' {
                    $page.Override['Input.dispatchMouseEvent'] = $mouse
                    $script:ReleaseAnswer = {
                        param($Message)
                        (New-WebTestReply -Message $Message)
                        @{ method = 'Browser.downloadWillBegin'; params = @{ frameId = 'T1'; guid = 'g1'; url = 'http://localhost:8080/f.bin'; suggestedFilename = 'f.bin' }; _afterMs = 10 }
                    }
                    $step = $click
                }
                'an open starts a download' {
                    $page.Override['Page.navigate'] = { param($Message) New-WebTestReply -Message $Message -Result @{ frameId = 'T1'; errorText = 'net::ERR_ABORTED'; isDownload = $true } }
                    $step = $openStep
                }
                'a reply is too large' {
                    $page.Override['Accessibility.getFullAXTree'] = { param($Message) New-WebTestError -Message $Message -Code -32099 -Text 'reply larger than 33554432 bytes' }
                    $step = $expectDone
                }
                'the page crashes' {
                    $preEvent = @{ method = 'Inspector.targetCrashed'; sessionId = 'S1'; params = @{} }
                    $step = $expectDone
                }
                'a read gets no reply' {
                    $page.Override['Accessibility.getFullAXTree'] = { param($Message) $null = $Message }
                    $step = $click
                }
                'a release gets no reply' {
                    $page.Override['Input.dispatchMouseEvent'] = $mouse
                    $script:ReleaseAnswer = { param($Message) $null = $Message }
                    $step = $click
                }
                'the socket closes' {
                    $page.Override['Accessibility.getFullAXTree'] = { param($Message) $null = $Message; 'close' }
                    $step = $expectDone
                }
                'no address is found' { $noEntry = $true; $step = $openStep }
                'the guest has no browser' { $noEntry = $true; $step = $openStep }
                'the browser lacks a command' {
                    $page.Override['Accessibility.getFullAXTree'] = { param($Message) New-WebTestError -Message $Message -Code -32601 -Text "'Accessibility.getFullAXTree' wasn't found" }
                    $step = $expectDone
                }
                'a locator mixes css and role' { $step = [ordered]@{ action = 'webClick'; css = '#go'; role = 'button' } }
                'no page is open' { $noEntry = $true; $step = $click }
                'an expected page stops answering' {
                    $page.Override['Accessibility.getFullAXTree'] = { param($Message) $null = $Message }
                    $step = $expectDone
                }
                'a dialog blocks a read' {
                    $page.Override['Accessibility.getFullAXTree'] = {
                        param($Message)
                        $null = $Message
                        @{ method = 'Page.javascriptDialogOpening'; sessionId = 'S1'; params = @{ type = 'alert'; message = 'hello'; url = 'http://localhost:8080/' } }
                    }
                    $step = $expectDone
                }
                default { throw "no row named $Situation" }
            }
            if (-not $step.Contains('timeoutSeconds')) { $step.timeoutSeconds = 30 }
            $t = New-WebTestConnection -Responder (New-WebTestPage @page) -Clock (New-WebTestClock -Now ([DateTime]::UtcNow))
            $script:CaseEntry = if ($noEntry) { $null } else { New-WebTestSession -Connection $t.Connection }
            if ($preEvent) { Add-WebTestEvent -Transport $t.Transport -Event $preEvent }
            $threw = $null
            $result = $null
            try {
                $result = & (Get-SequenceAction -Name $step.action).Handler (New-WebTestContext -Step $step)
            } catch {
                $threw = $_
            }
            return @{ Result = $result; Threw = $threw; Slot = (Get-SequenceFailureState).StepWebFailure; Transport = $t.Transport; Connection = $t.Connection }
        }

        function Invoke-WebTestChild {
            param([Parameter(Mandatory)][string]$Command)
            $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($argument in '-NoProfile', '-NonInteractive', '-Command', $Command) { $info.ArgumentList.Add($argument) }
            $info.Environment['NO_COLOR'] = '1'
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.UseShellExecute = $false
            $process = [System.Diagnostics.Process]::Start($info)
            try {
                $out = $process.StandardOutput.ReadToEndAsync()
                $err = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(180000)) {
                    $process.Kill($true)
                    throw 'the child process did not end within 180 s'
                }
                $process.WaitForExit()
                return @{ ExitCode = $process.ExitCode; Out = $out.GetAwaiter().GetResult(); Err = $err.GetAwaiter().GetResult() }
            } finally {
                $process.Dispose()
            }
        }

        $script:FillSequencePath = Join-Path $TestDrive 'workload.fixture.page-fill.yml'
        Set-Content -LiteralPath $script:FillSequencePath -Encoding utf8 -Value @'
description: "Page fill fixture."
keystrokeMechanism: ssh
resource:
  ubuntu.server.26: []
workload:
  - action: webFill
    role: textbox
    name: "Name"
    text: "x"
'@
    }
    BeforeEach {
        $script:CaseEntry = $null
        Mock Get-GuestWebSession -ModuleName Test.WebHandler { $script:CaseEntry }
        Mock Test-GuestWebSession -ModuleName Test.WebHandler { @{ Alive = $true; Code = ''; Detail = '' } }
        Mock Close-GuestWebSession -ModuleName Test.WebHandler { 1 }
    }

    It 'files <Situation> as <Kind> with effect <Effect>' -ForEach @(
        @{ Situation = 'nothing matches'; Kind = 'not_found'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'no option has the label'; Kind = 'not_found'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'two elements match'; Kind = 'ambiguous'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'the element stays disabled'; Kind = 'not_actionable'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'a text never shows'; Kind = 'expectation'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'a filled value reads back changed'; Kind = 'expectation'; Class = 'web_step_failed'; Effect = 'applied' }
        @{ Situation = 'a navigation fails'; Kind = 'navigation'; Class = 'web_step_failed'; Effect = 'applied' }
        @{ Situation = 'the browser refuses the URL'; Kind = 'navigation'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'a dialog opens'; Kind = 'unsupported'; Class = 'web_step_failed'; Effect = 'uncertain' }
        @{ Situation = 'the page opens a window'; Kind = 'unsupported'; Class = 'web_step_failed'; Effect = 'applied' }
        @{ Situation = 'a download begins'; Kind = 'unsupported'; Class = 'web_step_failed'; Effect = 'applied' }
        @{ Situation = 'an open starts a download'; Kind = 'unsupported'; Class = 'web_step_failed'; Effect = 'applied' }
        @{ Situation = 'a reply is too large'; Kind = 'unsupported'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'the page crashes'; Kind = 'page_lost'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'a read gets no reply'; Kind = 'page_lost'; Class = 'web_step_failed'; Effect = 'none-proven' }
        @{ Situation = 'a release gets no reply'; Kind = 'page_lost'; Class = 'web_step_failed'; Effect = 'uncertain' }
        @{ Situation = 'the socket closes'; Kind = 'transport'; Class = 'network_timeout'; Effect = 'none-proven' }
        @{ Situation = 'no address is found'; Kind = 'address_unresolved'; Class = 'ip_not_discovered'; Effect = 'none-proven' }
        @{ Situation = 'the guest has no browser'; Kind = 'browser_unavailable'; Class = 'plan_invalid'; Effect = 'uncertain' }
        @{ Situation = 'the browser lacks a command'; Kind = 'protocol'; Class = 'plan_invalid'; Effect = 'none-proven' }
        @{ Situation = 'a locator mixes css and role'; Kind = 'invalid_step'; Class = 'plan_invalid'; Effect = 'none-proven' }
        @{ Situation = 'no page is open'; Kind = 'invalid_step'; Class = 'plan_invalid'; Effect = 'none-proven' }
        @{ Situation = 'an expected page stops answering'; Kind = 'page_lost'; Class = 'web_step_failed'; Effect = 'none-proven' }
    ) {
        if ($Situation -ceq 'no address is found') {
            Mock Open-GuestWebSession -ModuleName Test.WebHandler { @{ Ok = $false; Session = $null; Kind = 'address_unresolved'; Code = 'address-unresolved'; Detail = 'no address for fixture-vm' } }
        }
        if ($Situation -ceq 'the guest has no browser') {
            Mock Open-GuestWebSession -ModuleName Test.WebHandler {
                $Effect['Dispatched'] = $true
                @{ Ok = $false; Session = $null; Kind = 'browser_unavailable'; Code = 'launcher-refused'; Detail = 'browser-not-found: x' }
            }
        }
        $row = Invoke-PageFailureRow -Situation $Situation
        Assert-Null $row.Threw "no exception leaves the handler: $($row.Threw)"
        Assert-True ($row.Result -is [bool]) 'the handler returns a strict boolean'
        Assert-False $row.Result "$Situation fails the step"
        Assert-StringEqual -Expected $Kind -Actual ([string]$row.Slot.kind) -Because "detail: $($row.Slot.detail)"
        Assert-StringEqual -Expected $Class -Actual ([string]$row.Slot.failureClass)
        Assert-StringEqual -Expected $Effect -Actual ([string]$row.Slot.effect)
        switch ($Situation) {
            'two elements match' {
                Assert-Equal -Expected 2 -Actual @($row.Slot.candidates).Count
                Assert-Equal -Expected 2 -Actual ([int]$row.Slot.matchCount)
            }
            'a dialog opens' {
                Assert-StringEqual -Expected 'dialog: alert' -Actual ([string]$row.Slot.detail)
                $handled = @($row.Transport.State.Sent | Where-Object { $_['method'] -ceq 'Page.handleJavaScriptDialog' })
                Assert-Equal -Expected 1 -Actual $handled.Count
                Assert-True ($handled[0]['params']['accept'] -eq $false) 'the dialog is dismissed'
            }
            'the socket closes' {
                Should -Invoke Close-GuestWebSession -ModuleName Test.WebHandler -Times 1 -Exactly -ParameterFilter { $Reason -ceq 'web-transport' }
            }
            'a locator mixes css and role' { Assert-Equal -Expected 0 -Actual $row.Transport.State.Sent.Count -Because 'nothing is sent' }
            'no page is open' { Assert-StringEqual -Expected 'no page open' -Actual ([string]$row.Slot.detail) }
            'a filled value reads back changed' { Assert-StringEqual -Expected 'value differs: wanted 9 characters, read 5' -Actual ([string]$row.Slot.detail) }
            'an expected page stops answering' { Assert-StringEqual -Expected 'no reply to Accessibility.getFullAXTree' -Actual ([string]$row.Slot.detail) }
        }
    }

    It 'files a dialog before the missing reply it causes' {
        $row = Invoke-PageFailureRow -Situation 'a dialog blocks a read'
        Assert-Null $row.Threw "no exception leaves the handler: $($row.Threw)"
        Assert-False $row.Result 'the step fails'
        Assert-StringEqual -Expected 'unsupported' -Actual ([string]$row.Slot.kind)
        Assert-StringEqual -Expected 'dialog: alert' -Actual ([string]$row.Slot.detail)
    }

    It 'registers the seven page verbs when the handler module alone is loaded in a new process' {
        $module = (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1').Replace("'", "''")
        $listing = Invoke-WebTestChild -Command (@"
Import-Module '$module' -DisableNameChecking
`$names = [string[]]@(Get-SequenceActionName | Where-Object { `$_ -like 'web*' })
[Array]::Sort(`$names, [StringComparer]::Ordinal)
foreach (`$n in `$names) {
    `$a = Get-SequenceAction -Name `$n
    'LINE {0} {1} {2} {3} {4}' -f `$n, `$a.FailureClass, `$a.Severity, `$a.ReplaySafety, (@(`$a.HostCommandRequirement) -join ',')
}
"@)
        Assert-Equal -Expected 0 -Actual $listing.ExitCode -Because $listing.Err
        $lines = @(($listing.Out -split '\r?\n') | Where-Object { $_.StartsWith('LINE ', [StringComparison]::Ordinal) } | ForEach-Object { $_.Substring(5) })
        $expected = @(
            'webClick web_step_failed hard input ssh,ssh-keygen'
            'webClose web_step_failed hard state-changing ssh,ssh-keygen'
            'webExpect web_step_failed hard observe ssh,ssh-keygen'
            'webFill web_step_failed hard input ssh,ssh-keygen'
            'webOpen web_step_failed hard state-changing ssh,ssh-keygen'
            'webPress web_step_failed hard input ssh,ssh-keygen'
            'webSelect web_step_failed hard input ssh,ssh-keygen'
        )
        Assert-StringEqual -Expected ($expected -join "`n") -Actual ($lines -join "`n")
        $again = Invoke-WebTestChild -Command (@"
Import-Module '$module' -DisableNameChecking
Clear-SequenceAction -Confirm:`$false
Import-Module '$module' -Force -Global -DisableNameChecking
'COUNT ' + @(Get-SequenceActionName | Where-Object { `$_ -like 'web*' }).Count
"@)
        Assert-Equal -Expected 0 -Actual $again.ExitCode -Because $again.Err
        $count = @(($again.Out -split '\r?\n') | Where-Object { $_.StartsWith('COUNT ', [StringComparison]::Ordinal) })
        Assert-StringEqual -Expected 'COUNT 7' -Actual ([string]$count[-1])
    }

    It 'lists every page verb that needs an open page in the warm resume rule' {
        $dependent = @(Get-SequenceActionName | Where-Object { $_ -like 'web*' -and $_ -cne 'webOpen' -and $_ -cne 'webClose' })
        Assert-Equal -Expected 5 -Actual $dependent.Count -Because ($dependent -join ',')
        foreach ($pageVerb in $dependent) {
            Assert-StringEqual -Expected $pageVerb -Actual (Get-WarmResumeFirstPageVerb -Step @(@{ action = $pageVerb }))
        }
    }

    It 'leaves no typed value in the record of a sensitive fill' {
        $value = 'fixture-value-9'
        $t = New-WebTestConnection -Clock (New-WebTestClock -Now ([DateTime]::UtcNow)) -Responder (New-WebTestPage `
                -Ax @{ S1 = @((New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'Page' -Children 2 -Backend 1),
                    (New-WebTestAxNode -Id 2 -Role textbox -Name 'Secret' -Backend 30 -Props @{ editable = 'plaintext' })) } `
                -Quads @{ 30 = @(10, 10, 90, 10, 90, 30, 10, 30) } `
                -Partial @{ 30 = (New-WebTestAxNode -Id 2 -Role textbox -Name 'Secret' -Backend 30 -Value 'fixture' -Props @{ editable = 'plaintext' }) })
        $script:CaseEntry = New-WebTestSession -Connection $t.Connection
        $step = [ordered]@{ action = 'webFill'; role = 'textbox'; name = 'Secret'; text = $value; sensitive = $true; timeoutSeconds = 30 }
        $context = New-WebTestContext -Step $step
        Assert-False (& (Get-SequenceAction -Name 'webFill').Handler $context) 'the fill whose value reads back changed fails'
        (Get-SequenceFailureState).LastFailedAction = 'webFill'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:FillSequencePath -LogDir $TestDrive -TotalSteps 1
        $fileJson = $r.File | ConvertTo-Json -Depth 12
        $eventJson = $r.Event | ConvertTo-Json -Depth 12
        Assert-Match -Pattern 'value differs' -Actual $fileJson
        Assert-False $fileJson.Contains($value) 'the record file holds no typed value'
        Assert-False $eventJson.Contains($value) 'the event holds no typed value'
        $label = Get-SequenceActionFailureLabel -Step $step -Vars @{} -ExpandVariable $context.ExpandVariable -VMName 'v' -GuestKey 'g'
        Assert-False ([string]$label).Contains($value) "the label '$label' holds no typed value"
    }

    It 'leaves no typed value in the record of a fill that is not sensitive' {
        $value = 'plain-value-42'
        $t = New-WebTestConnection -Clock (New-WebTestClock -Now ([DateTime]::UtcNow)) -Responder (New-WebTestPage `
                -Ax @{ S1 = @((New-WebTestAxNode -Id 1 -Role RootWebArea -Name 'Page' -Children 2 -Backend 1),
                    (New-WebTestAxNode -Id 2 -Role textbox -Name 'Name' -Backend 30 -Props @{ editable = 'plaintext' })) } `
                -Quads @{ 30 = @(10, 10, 90, 10, 90, 30, 10, 30) } `
                -Partial @{ 30 = (New-WebTestAxNode -Id 2 -Role textbox -Name 'Name' -Backend 30 -Value 'plain' -Props @{ editable = 'plaintext' }) })
        $script:CaseEntry = New-WebTestSession -Connection $t.Connection
        $step = [ordered]@{ action = 'webFill'; role = 'textbox'; name = 'Name'; text = $value; timeoutSeconds = 30 }
        Assert-False (& (Get-SequenceAction -Name 'webFill').Handler (New-WebTestContext -Step $step)) 'the fill whose value reads back changed fails'
        (Get-SequenceFailureState).LastFailedAction = 'webFill'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:FillSequencePath -LogDir $TestDrive -TotalSteps 1
        Assert-True ([string]$r.File.context.causeDetail.web.detail).StartsWith('value differs', [StringComparison]::Ordinal) 'the account says the value differs'
        Assert-False ($r.File | ConvertTo-Json -Depth 12).Contains($value) 'the record file holds no typed value'
        Assert-False ($r.Event | ConvertTo-Json -Depth 12).Contains($value) 'the event holds no typed value'
    }
}
