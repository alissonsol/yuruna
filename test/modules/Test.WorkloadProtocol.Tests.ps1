<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42110e90-a4ea-4e6b-bfc7-61cfdfecc8d2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload mcp protocol pester
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
    Pester guard on Test.WorkloadProtocol.psm1, what the workload MCP front end
    and its worker share.
.DESCRIPTION
    The front end and the worker read each other's frames, agree on limits and
    operation ids, and hand references to a client. A frame that changed a time
    stamp or a key on its way, an id pattern that let a line feed through, a
    hash that depended on key order, or a reference that moved when a filter hid
    an entry would make a client act on the wrong thing with every check green.
    The cases pin the frame round trip, the limits, the id pattern, the input
    hash, the snapshot grammar with its references and truncation, the
    owned-process cleanup and the mask sink.

    Two cases start sleeping pwsh children and end them before they finish.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.WorkloadProtocol.psm1') -Force -DisableNameChecking

    function Get-ProtocolFixtureSegment {
        <#
        .SYNOPSIS
            OCR segments in the shape of Get-OcrWordBoxLine, numbered from one.
        #>
        param([Parameter(Mandatory)][int]$Count)
        return , ([object[]]@(for ($i = 1; $i -le $Count; $i++) {
                    @{ text = "entry $i"; x = 0; y = $i * 16; w = 80; h = 16; block = 1; par = 1; line = $i; segment = 1 }
                }))
    }

    function Start-ProtocolFixtureSleeper {
        <#
        .SYNOPSIS
            Starts one pwsh child that sleeps, for the cleanup cases.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: starts a child process the case ends itself.')]
        param()
        $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120')) { $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.Environment['NO_COLOR'] = '1'
        return [System.Diagnostics.Process]::Start($info)
    }
}

Describe 'frames and limits' {
    It 'round-trips a frame with dates, mixed-case keys and non-ASCII text unchanged' {
        $text = "caf`u{e9} `u{5916}"
        $line = '{"type":"reply","id":"r1","result":{"ok":true,"when":"2026-11-17T03:15:02.123+01:00","a":"lower","A":"upper","text":"' + $text + '"}}'
        $frame = ConvertFrom-WorkloadFrameLine -Line $line
        $again = ConvertFrom-WorkloadFrameLine -Line (ConvertTo-WorkloadFrameLine -Frame $frame)
        foreach ($read in @($frame, $again)) {
            Assert-True ($read.result['when'] -is [string]) "the time stamp became $($read.result['when'].GetType().FullName)"
            Assert-True ([string]::Equals('2026-11-17T03:15:02.123+01:00', $read.result['when'], [StringComparison]::Ordinal)) "the time stamp changed to '$($read.result['when'])'"
            Assert-True ([string]::Equals('lower', $read.result['a'], [StringComparison]::Ordinal)) 'the key a lost its value'
            Assert-True ([string]::Equals('upper', $read.result['A'], [StringComparison]::Ordinal)) 'the key A lost its value'
            Assert-True ([string]::Equals($text, $read.result['text'], [StringComparison]::Ordinal)) "the text changed to '$($read.result['text'])'"
            Assert-True ($read.result['ok'] -eq $true)
        }
    }

    It 'rejects a line that is too long, not an object, or without a type' {
        $limit = (Get-WorkloadProtocolLimit).MaxFrameChars
        $long = '{"type":"reply","x":"' + ('a' * $limit) + '"}'
        foreach ($line in @($long, '[1,2]', '"text"', 'not json', '{"id":"r1"}', '{"type":3}')) {
            $caught = $null
            try { $null = ConvertFrom-WorkloadFrameLine -Line $line } catch { $caught = $_.Exception }
            Assert-NotNull $caught "a line of length $($line.Length) was accepted"
            Assert-True ($caught -is [System.FormatException]) "a line threw $($caught.GetType().FullName)"
        }
    }

    It 'keeps a client line of the longest accepted length inside one frame' {
        $limits = Get-WorkloadProtocolLimit
        $head = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workload_step","arguments":{"operationId":"op-1","step":"say \"x\" \\ '
        $tail = '"}}}'
        $clientLine = $head + ('a' * ($limits.MaxRequestLineChars - $head.Length - $tail.Length)) + $tail
        Assert-Equal $limits.MaxRequestLineChars $clientLine.Length
        $request = ConvertFrom-Json -InputObject $clientLine -AsHashtable -DateKind String
        $frame = [ordered]@{ type = 'request'; id = 'r1'; method = 'step.run'; params = $request.params.arguments }
        $frameLine = ConvertTo-WorkloadFrameLine -Frame $frame
        Assert-True ($frameLine.Length -le $limits.MaxFrameChars) "the frame is $($frameLine.Length) characters"
        Assert-True ((ConvertFrom-WorkloadFrameLine -Line $frameLine).params.step.StartsWith('say "x" \ ', [StringComparison]::Ordinal))
    }

    It 'accepts and refuses operation ids by the documented pattern' {
        $table = @(
            @{ Value = 'a'; Expected = $true }
            @{ Value = 'author-0007'; Expected = $true }
            @{ Value = ('a' * 64); Expected = $true }
            @{ Value = ''; Expected = $false }
            @{ Value = ('a' * 65); Expected = $false }
            @{ Value = '-a'; Expected = $false }
            @{ Value = 'a b'; Expected = $false }
            @{ Value = 'a/b'; Expected = $false }
            @{ Value = "a`n"; Expected = $false }
        )
        foreach ($row in $table) {
            Assert-Equal $row.Expected (Test-WorkloadOperationId -Value $row.Value) "id '$($row.Value)' of length $($row.Value.Length)"
        }
    }

    It 'hashes equal input equally whatever the key order' {
        $first = Get-WorkloadInputHash -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'wait for text login'; timeoutSeconds = 60 })
        $second = Get-WorkloadInputHash -Tool 'workload_step' -Arguments ([ordered]@{ timeoutSeconds = 60; step = 'wait for text login'; operationId = 'op-1' })
        $double = Get-WorkloadInputHash -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'wait for text login'; timeoutSeconds = 60.0 })
        $changed = Get-WorkloadInputHash -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'wait for text login'; timeoutSeconds = 61 })
        $otherTool = Get-WorkloadInputHash -Tool 'workload_action' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'wait for text login'; timeoutSeconds = 60 })
        Assert-Match '^[0-9a-f]{64}$' $first
        Assert-StringEqual $first $second 'the key order changed the hash'
        Assert-StringEqual $first $double '60 and 60.0 hash differently'
        Assert-NotEqual $first $changed 'a changed value kept the hash'
        Assert-NotEqual $first $otherTool 'another tool kept the hash'
    }

    It 'lists exactly the documented limits' {
        $expected = [ordered]@{
            PipeProtocol             = 1
            MaxFrameChars            = 1048576
            MaxRequestLineChars      = 1000000
            MaxSnapshotInlineChars   = 40000
            MaxSnapshotInlineEntries = 400
            MaxSnapshotFileChars     = 1000000
            MaxImageBytes            = 2097152
            MaxPhraseEntries         = 500
            MaxWorkerLogChars        = 8388608
            MaxQueuedCalls           = 16
            SessionFolderRetention   = 20
            ReferenceBlock           = 1000000
            MaskAckSeconds           = 5
        }
        $limits = Get-WorkloadProtocolLimit
        Assert-StringEqual (@($expected.Keys) -join ',') (@($limits.Keys) -join ',')
        foreach ($name in $expected.Keys) { Assert-Equal $expected[$name] $limits[$name] "limit $name" }
    }
}

Describe 'the screen snapshot text' {
    It 'quotes text with escaped quotes and backslashes and no control characters' {
        Assert-True ([string]::Equals('"a\"b \\c"', (ConvertTo-WorkloadQuotedText -Text ("a`"b`t\c")), [StringComparison]::Ordinal))
    }

    It 'writes one line entry per segment with its box' {
        $segments = @(
            @{ text = 'Ubuntu 24.04.3 LTS test-ubuntu tty1'; x = 0; y = 0; w = 412; h = 16; block = 1; par = 1; line = 1; segment = 1 }
            @{ text = 'test-ubuntu login:'; x = 0; y = 32; w = 208; h = 16; block = 1; par = 1; line = 2; segment = 1 }
            @{ text = 'Name'; x = 0; y = 64; w = 60; h = 16; block = 2; par = 1; line = 1; segment = 1 }
            @{ text = "Say `"hi`"  \ there"; x = 300; y = 64; w = 120; h = 16; block = 2; par = 1; line = 1; segment = 2 }
        )
        $result = ConvertTo-WorkloadScreenSnapshot -Line $segments -OtherText $null -VmName 'test-guest.ubuntu.server.24-01' `
            -FrameName 'raw_20261117T031502113Z.png' -Ordinal 7 -ReferenceBase 0 -Find ''
        $expected = @'
# surface: screen   snapshot: 7   vm: test-guest.ubuntu.server.24-01   frame: raw_20261117T031502113Z.png
- line "Ubuntu 24.04.3 LTS test-ubuntu tty1" [ref=s1] [box=0,0,412,16]
- line "test-ubuntu login:" [ref=s2] [box=0,32,208,16]
- line "Name" [ref=s3] [box=0,64,60,16]
- line "Say \"hi\" \\ there" [ref=s4] [box=300,64,120,16]
'@ -replace "`r`n", "`n"
        Assert-True ([string]::Equals($expected, $result.InlineText, [StringComparison]::Ordinal)) "inline text:`n$($result.InlineText)"
        Assert-True ([string]::Equals($expected, $result.FileText, [StringComparison]::Ordinal)) "file text:`n$($result.FileText)"
        Assert-StringEqual 's1,s2,s3,s4' (@($result.Table.Keys) -join ',')
        Assert-Equal 4 $result.Entries
        Assert-Equal 4 $result.Shown
        Assert-False $result.Truncated
        Assert-Equal 300 $result.Table['s4'].X
        Assert-Equal 2 $result.Table['s4'].Segment
    }

    It 'gives every line a reference even when a filter or a limit hides it' {
        $segments = Get-ProtocolFixtureSegment -Count 500
        foreach ($find in @('entry 17', '')) {
            $result = ConvertTo-WorkloadScreenSnapshot -Line $segments -OtherText $null -VmName 'vm' -FrameName 'f.png' -Ordinal 1 -ReferenceBase 42 -Find $find
            Assert-Equal 500 $result.Table.Count "find '$find'"
            Assert-Equal 542 $result.ReferenceBase "find '$find'"
            Assert-True ($result.Table.Contains('s43') -and $result.Table.Contains('s542')) "find '$find'"
        }
        $filtered = ConvertTo-WorkloadScreenSnapshot -Line $segments -OtherText $null -VmName 'vm' -FrameName 'f.png' -Ordinal 1 -ReferenceBase 42 -Find 'ENTRY 17'
        Assert-Match '\[ref=s59\]' $filtered.InlineText 'a filtered entry kept its reference'
        Assert-Equal 11 $filtered.Entries 'entry 17 and entry 170 to 179 contain the filter'
    }

    It 'states the truncation and keeps the file complete' {
        $result = ConvertTo-WorkloadScreenSnapshot -Line (Get-ProtocolFixtureSegment -Count 500) -OtherText $null -VmName 'vm' -FrameName 'f.png' -Ordinal 1 -ReferenceBase 0 -Find ''
        $inline = $result.InlineText -split "`n"
        Assert-StringEqual '# truncated: shown=400 entries=500' $inline[-1]
        Assert-Equal 400 @($inline | Where-Object { $_.StartsWith('- line ') }).Count
        Assert-Equal 500 @(($result.FileText -split "`n") | Where-Object { $_.StartsWith('- line ') }).Count
        Assert-False ($result.FileText.Contains('# truncated', [StringComparison]::Ordinal)) 'the file text was cut'
        Assert-Equal 500 $result.Entries
        Assert-Equal 400 $result.Shown
        Assert-True $result.Truncated
    }

    It 'appends text only another engine read, without a reference' {
        $segments = @(@{ text = 'test-ubuntu login:'; x = 0; y = 32; w = 208; h = 16; block = 1; par = 1; line = 1; segment = 1 })
        $other = [ordered]@{
            tesseract = 'only tesseract read this'
            winrt     = "test-ubuntu  login:`nPress F1 for help`npress f1 for help"
        }
        $result = ConvertTo-WorkloadScreenSnapshot -Line $segments -OtherText $other -VmName 'vm' -FrameName 'f.png' -Ordinal 1 -ReferenceBase 0 -Find ''
        $lines = $result.FileText -split "`n"
        Assert-Equal 1 @($lines | Where-Object { $_ -ceq '- text "Press F1 for help" [engine=winrt]' }).Count
        Assert-Equal 1 @($lines | Where-Object { $_.StartsWith('- text ') }).Count 'a duplicate was appended'
        Assert-False ($result.FileText.Contains('only tesseract', [StringComparison]::Ordinal)) 'the tesseract text was appended'
        Assert-Equal 1 $result.Table.Count
    }

    It 'continues the ordinals from the reference base it is given' {
        $result = ConvertTo-WorkloadScreenSnapshot -Line (Get-ProtocolFixtureSegment -Count 2) -OtherText $null -VmName 'vm' -FrameName 'f.png' -Ordinal 3 -ReferenceBase 1000000 -Find ''
        Assert-StringEqual 's1000001' @($result.Table.Keys)[0]
        Assert-Match '\[ref=s1000001\]' (($result.InlineText -split "`n")[1])
        Assert-Equal 1000002 $result.ReferenceBase
    }
}

Describe 'the page snapshot text' {
    BeforeAll {
        # Display entries in the shape Get-WebPageSnapshotEntry returns. This
        # suite does not load Test.WebSession.psm1, so they are written by hand.
        function New-ProtocolPageEntry {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory display entry.')]
            param(
                [string]$Kind = 'node',
                [int]$Indent = 0,
                [string]$Role = '',
                [string]$Name = '',
                [string[]]$Tags = @(),
                [int]$Backend = 0
            )
            $address = if ($Backend -gt 0) { @{ SessionId = 'S1'; BackendNodeId = $Backend; Owners = [object[]]@() } } else { $null }
            return @{ Kind = $Kind; Indent = $Indent; Role = $Role; Name = $Name; Tags = $Tags; Address = $address }
        }
    }

    It 'writes the page header and one line per entry' {
        $entries = @(
            New-ProtocolPageEntry -Indent 0 -Role 'main' -Name '' -Backend 10
            New-ProtocolPageEntry -Indent 1 -Role 'heading' -Name 'Sign in' -Tags @('level=1') -Backend 11
            New-ProtocolPageEntry -Indent 1 -Role 'form' -Name 'Login'
            New-ProtocolPageEntry -Indent 2 -Role 'textbox' -Name 'Username' -Tags @('value="maria"') -Backend 12
            New-ProtocolPageEntry -Indent 2 -Role 'checkbox' -Name 'Remember me' -Tags @('checked=false') -Backend 13
            New-ProtocolPageEntry -Indent 2 -Role 'button' -Name 'Sign in' -Tags @('disabled=true') -Backend 14
            New-ProtocolPageEntry -Kind 'text' -Indent 2 -Name 'Forgot "it"?'
        )
        $result = ConvertTo-WorkloadPageSnapshot -Entry $entries -Url 'http://localhost:8080/login' -Title 'Sign in' -Generation 2 -Ordinal 1 -ReferenceBase 0 -Find ''
        $expected = @'
# surface: page   snapshot: 1   url: http://localhost:8080/login   title: Sign in
- main [ref=p1]
  - heading "Sign in" [level=1] [ref=p2]
  - form "Login"
    - textbox "Username" [value="maria"] [ref=p3]
    - checkbox "Remember me" [checked=false] [ref=p4]
    - button "Sign in" [disabled=true] [ref=p5]
    - text "Forgot \"it\"?"
'@ -replace "`r`n", "`n"
        Assert-True ([string]::Equals($expected, $result.FileText, [StringComparison]::Ordinal)) "file text:`n$($result.FileText)"
        Assert-True ([string]::Equals($expected, $result.InlineText, [StringComparison]::Ordinal)) "inline text:`n$($result.InlineText)"
        Assert-StringEqual 'p1,p2,p3,p4,p5' (@($result.Table.Keys) -join ',')
        Assert-StringEqual 'textbox' $result.Table['p3'].Role
        Assert-StringEqual 'Username' $result.Table['p3'].Name
        Assert-Equal 12 $result.Table['p3'].Address.BackendNodeId
        Assert-Equal 2 $result.Table['p3'].Generation
        Assert-Equal 7 $result.Entries
        Assert-False $result.Truncated
        $found = ConvertTo-WorkloadPageSnapshot -Entry $entries -Url 'http://localhost:8080/login' -Title 'Sign in' -Generation 2 -Ordinal 2 -ReferenceBase 0 -Find 'user'
        Assert-StringEqual '# surface: page   snapshot: 2   url: http://localhost:8080/login   title: Sign in   find: "user"' (($found.InlineText -split "`n")[0])
    }

    It 'numbers every addressed node whatever the filter' {
        $entries = @(for ($i = 1; $i -le 500; $i++) {
                New-ProtocolPageEntry -Indent 0 -Role 'button' -Name "entry $i" -Backend $i
                if ($i % 50 -eq 0) { New-ProtocolPageEntry -Kind 'text' -Indent 0 -Name "note $i" }
            })
        foreach ($findText in @('entry 17', '')) {
            $result = ConvertTo-WorkloadPageSnapshot -Entry $entries -Url 'http://localhost/' -Title '' -Generation 1 -Ordinal 1 -ReferenceBase 42 -Find $findText
            Assert-Equal 500 $result.Table.Count "find '$findText'"
            Assert-Equal 542 $result.ReferenceBase "find '$findText'"
            Assert-StringEqual 'p43' @($result.Table.Keys)[0] "find '$findText'"
            Assert-True ($result.Table.Contains('p542')) "find '$findText'"
        }
        $filtered = ConvertTo-WorkloadPageSnapshot -Entry $entries -Url 'http://localhost/' -Title '' -Generation 1 -Ordinal 1 -ReferenceBase 42 -Find 'ENTRY 17'
        Assert-Match '"entry 17" \[ref=p59\]' $filtered.InlineText 'a filtered entry kept its reference'
        Assert-Equal 11 $filtered.Entries 'entry 17 and entry 170 to 179 contain the filter'
    }

    It 'states the truncation of a long page and keeps the file complete' {
        $limit = (Get-WorkloadProtocolLimit).MaxSnapshotInlineEntries
        $count = $limit + 100
        $entries = @(for ($i = 1; $i -le $count; $i++) { New-ProtocolPageEntry -Indent 0 -Role 'link' -Name "item $i" -Backend $i })
        $result = ConvertTo-WorkloadPageSnapshot -Entry $entries -Url 'http://localhost/' -Title 'Long' -Generation 1 -Ordinal 1 -ReferenceBase 0 -Find ''
        $inline = $result.InlineText -split "`n"
        Assert-StringEqual ('# truncated: shown={0} entries={1}' -f $limit, $count) $inline[-1]
        Assert-Equal $limit @($inline | Where-Object { $_.StartsWith('- link ') }).Count
        Assert-Equal $count @(($result.FileText -split "`n") | Where-Object { $_.StartsWith('- link ') }).Count
        Assert-False ($result.FileText.Contains('# truncated', [StringComparison]::Ordinal)) 'the file text was cut'
        Assert-True $result.Truncated
        Assert-Equal $limit $result.Shown
        Assert-Equal $count $result.Entries
    }
}

Describe 'owned processes and the mask sink' {
    AfterEach {
        Register-WorkloadMaskSink -ScriptBlock $null
    }

    It 'kills only a listed process whose start time matches' {
        $session = Join-Path $TestDrive 'session-owned'
        $null = New-Item -ItemType Directory -Path $session -Force
        $listed = Start-ProtocolFixtureSleeper
        $shifted = Start-ProtocolFixtureSleeper
        try {
            $listedTicks = $listed.StartTime.ToUniversalTime().Ticks
            $shiftedTicks = $shifted.StartTime.ToUniversalTime().Ticks + 10 * [TimeSpan]::TicksPerSecond
            Register-WorkloadOwnedProcess -SessionDir $session -ProcessId $listed.Id -StartTicks $listedTicks -Role 'fixture'
            Register-WorkloadOwnedProcess -SessionDir $session -ProcessId $shifted.Id -StartTicks $shiftedTicks -Role 'fixture'
            $listing = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $session 'owned-processes.json'))) -AsHashtable -NoEnumerate
            Assert-Equal 2 @($listing).Count
            $killed = Invoke-WorkloadOwnedProcessCleanup -SessionDir $session
            Assert-StringEqual ([string]$listed.Id) ($killed -join ',')
            Assert-True ($listed.WaitForExit(20000)) 'the listed process is still running'
            Assert-False $shifted.HasExited 'a process whose start time does not match was ended'
            Assert-False (Test-Path -LiteralPath (Join-Path $session 'owned-processes.json')) 'the list was kept'
        } finally {
            foreach ($process in @($listed, $shifted)) {
                if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(20000) }
                $process.Dispose()
            }
        }
    }

    It 'removes one process from the list and keeps the others' {
        $session = Join-Path $TestDrive 'session-unregister'
        $null = New-Item -ItemType Directory -Path $session -Force
        Register-WorkloadOwnedProcess -SessionDir $session -ProcessId 101 -StartTicks 5 -Role 'replay'
        Register-WorkloadOwnedProcess -SessionDir $session -ProcessId 202 -StartTicks 6 -Role 'browser'
        Unregister-WorkloadOwnedProcess -SessionDir $session -ProcessId 101
        $listing = @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $session 'owned-processes.json'))) -AsHashtable -NoEnumerate)
        $rows = @($listing | ForEach-Object { $_ })
        Assert-Equal 1 $rows.Count
        Assert-Equal 202 $rows[0]['pid']
        Assert-StringEqual 'browser' $rows[0]['role']
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $session -Filter '*.tmp').Count 'a temporary file was left'
    }

    It 'hands masks to the registered sink only' {
        Assert-True (Send-WorkloadMask -Value @('alpha-1')) 'without a sink the answer is true'
        $seen = [Collections.Generic.List[string[]]]::new()
        Register-WorkloadMaskSink -ScriptBlock { param([string[]]$Value) $seen.Add($Value); $false }.GetNewClosure()
        Assert-False (Send-WorkloadMask -Value @('alpha-1', '', 'beta-2')) 'the sink refused'
        Assert-Equal 1 $seen.Count
        Assert-StringEqual 'alpha-1,beta-2' ($seen[0] -join ',')
        Assert-True (Send-WorkloadMask -Value @('', '')) 'only empty values reached the sink'
        Assert-Equal 1 $seen.Count
        Register-WorkloadMaskSink -ScriptBlock $null
        Assert-True (Send-WorkloadMask -Value @('alpha-1')) 'a removed sink still answered'
    }
}
