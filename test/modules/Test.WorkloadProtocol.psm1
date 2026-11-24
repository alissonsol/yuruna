<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42f17380-99e5-426b-9d50-f51513b80f7e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload mcp protocol
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

# What the workload MCP front end and its worker share: the limits, the pipe
# frames between them, operation ids and input hashes, the processes a worker
# owns, the sink that hands secret values to the front end's log filter, and
# the text of a screen or page snapshot. The front end never loads the
# engine, so this module imports nothing of the sequence system.

Import-Module (Join-Path $PSScriptRoot 'Test.CanonicalJson.psm1') -DisableNameChecking

# The one sink of this process, set by the worker shell; $null means none.
$script:MaskSink = $null

function Get-WorkloadProtocolLimit {
    <#
    .SYNOPSIS
        The limits the front end and the worker agree on.
    .DESCRIPTION
        PipeProtocol is the number the worker sends in hello; it rises with any
        incompatible change of a frame or a request, so a front end and a
        worker of different code fail at hello instead of misreading frames.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return [ordered]@{
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
}

function ConvertTo-WorkloadFrameLine {
    <#
    .SYNOPSIS
        One pipe frame as one line of compact JSON, without the line feed.
    .DESCRIPTION
        Throws when the text is longer than MaxFrameChars, so a frame is never
        cut or split.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Frame)
    $line = ConvertTo-Json -InputObject $Frame -Compress -Depth 32
    $limit = (Get-WorkloadProtocolLimit).MaxFrameChars
    if ($line.Length -gt $limit) {
        throw [System.InvalidOperationException]::new("frame length $($line.Length) > MaxFrameChars $limit")
    }
    return $line
}

function ConvertFrom-WorkloadFrameLine {
    <#
    .SYNOPSIS
        One pipe frame read from one line.
    .DESCRIPTION
        Keeps time stamps and the case of keys as they were sent. Throws a
        FormatException for a line longer than MaxFrameChars, a line that is
        not a JSON object, and an object without a string type.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [object[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $limit = (Get-WorkloadProtocolLimit).MaxFrameChars
    if ($Line.Length -gt $limit) {
        throw [System.FormatException]::new("frame line length $($Line.Length) > MaxFrameChars $limit")
    }
    $frame = $null
    try {
        $frame = ConvertFrom-Json -InputObject $Line -AsHashtable -DateKind String -NoEnumerate -ErrorAction Stop
    } catch {
        throw [System.FormatException]::new("frame line is not JSON: $($_.Exception.Message)", $_.Exception)
    }
    if ($frame -isnot [System.Collections.IDictionary]) {
        throw [System.FormatException]::new('frame line is not a JSON object')
    }
    if (-not $frame.Contains('type') -or $frame['type'] -isnot [string]) {
        throw [System.FormatException]::new('frame has no string type')
    }
    return , $frame
}

function Test-WorkloadOperationId {
    <#
    .SYNOPSIS
        Whether a client's operation id has the documented form.
    .DESCRIPTION
        The pattern ends in \z, not $: a .NET $ also matches before a trailing
        line feed, and an id is compared, hashed and written into file names.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    return ([string]$Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z')
}

function Get-WorkloadInputHash {
    <#
    .SYNOPSIS
        The lowercase hex SHA-256 of a tool name and its arguments in canonical JSON.
    .DESCRIPTION
        Canonical JSON orders keys ordinally and writes numbers in the invariant
        culture, so the same input gives the same hash whatever the key order,
        and 60 and 60.0 hash alike.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [AllowNull()][System.Collections.IDictionary]$Arguments
    )
    $json = ConvertTo-CanonicalApprovalJson -Value ([ordered]@{ tool = $Tool; arguments = $Arguments })
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Test-WorkloadProcessIdentity {
    <#
    .SYNOPSIS
        Whether a process id still names the process that was recorded.
    .DESCRIPTION
        A pid is reused once its process ended; the start time, within one
        second, tells the recorded process from a later one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTicks
    )
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        try {
            if ($process.HasExited) { return $false }
            return ([Math]::Abs($process.StartTime.ToUniversalTime().Ticks - $StartTicks) -le [TimeSpan]::TicksPerSecond)
        } finally {
            $process.Dispose()
        }
    } catch {
        Write-Verbose "Process $ProcessId cannot be identified: $($_.Exception.Message)"
        return $false
    }
}

function Get-WorkloadOwnedProcessPath {
    # Private: the file that lists the processes of a session folder.
    param([Parameter(Mandatory)][string]$SessionDir)
    return (Join-Path $SessionDir 'owned-processes.json')
}

function Read-WorkloadOwnedProcess {
    # Private: the entries of the owned-process file, or an empty list.
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$SessionDir)
    $path = Get-WorkloadOwnedProcessPath -SessionDir $SessionDir
    $entries = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return , $entries.ToArray() }
    $text = [IO.File]::ReadAllText($path)
    if ([string]::IsNullOrWhiteSpace($text)) { return , $entries.ToArray() }
    $parsed = ConvertFrom-Json -InputObject $text -AsHashtable -DateKind String -NoEnumerate
    foreach ($entry in @($parsed)) {
        if ($entry -is [System.Collections.IDictionary]) { $entries.Add($entry) }
    }
    return , $entries.ToArray()
}

function Write-WorkloadOwnedProcess {
    # Private: replace the owned-process file through a temporary file.
    param(
        [Parameter(Mandatory)][string]$SessionDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry
    )
    $path = Get-WorkloadOwnedProcessPath -SessionDir $SessionDir
    $tmp = "$path.$PID.tmp"
    $rows = [object[]]@(foreach ($item in $Entry) {
            [ordered]@{ pid = [int]$item['pid']; startTicks = [long]$item['startTicks']; role = [string]$item['role'] }
        })
    $json = ConvertTo-Json -InputObject $rows -Depth 4
    [IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $path, $true)
}

function Register-WorkloadOwnedProcess {
    <#
    .SYNOPSIS
        Records a process the worker started that may outlive one call.
    .DESCRIPTION
        The record lets a later cleanup end the process even after the worker
        itself has exited, when Kill($true) on the worker reaches nothing.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$SessionDir,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTicks,
        [Parameter(Mandatory)][string]$Role
    )
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($entry in (Read-WorkloadOwnedProcess -SessionDir $SessionDir)) {
        if ([int]$entry['pid'] -ne $ProcessId) { $entries.Add($entry) }
    }
    $entries.Add(@{ pid = $ProcessId; startTicks = $StartTicks; role = $Role })
    Write-WorkloadOwnedProcess -SessionDir $SessionDir -Entry $entries.ToArray()
}

function Unregister-WorkloadOwnedProcess {
    <#
    .SYNOPSIS
        Removes a process from the session's owned-process file.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$SessionDir,
        [Parameter(Mandatory)][int]$ProcessId
    )
    if (-not (Test-Path -LiteralPath (Get-WorkloadOwnedProcessPath -SessionDir $SessionDir) -PathType Leaf)) { return }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($entry in (Read-WorkloadOwnedProcess -SessionDir $SessionDir)) {
        if ([int]$entry['pid'] -ne $ProcessId) { $entries.Add($entry) }
    }
    Write-WorkloadOwnedProcess -SessionDir $SessionDir -Entry $entries.ToArray()
}

function Invoke-WorkloadOwnedProcessCleanup {
    <#
    .SYNOPSIS
        Ends every listed process that is still the one recorded; returns their pids.
    .DESCRIPTION
        An entry whose pid now names another process, or none, is skipped. The
        file is deleted afterwards.
    #>
    [CmdletBinding()]
    [OutputType([int[]], [object[]])]
    param([Parameter(Mandatory)][string]$SessionDir)
    $killed = [Collections.Generic.List[int]]::new()
    $path = Get-WorkloadOwnedProcessPath -SessionDir $SessionDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return , $killed.ToArray() }
    $entries = @()
    try {
        $entries = Read-WorkloadOwnedProcess -SessionDir $SessionDir
    } catch {
        Write-Verbose "owned-processes.json in '$SessionDir' cannot be read: $($_.Exception.Message)"
    }
    foreach ($entry in $entries) {
        $processId = [int]$entry['pid']
        if (-not (Test-WorkloadProcessIdentity -ProcessId $processId -StartTicks ([long]$entry['startTicks']))) { continue }
        try {
            $process = [System.Diagnostics.Process]::GetProcessById($processId)
            try {
                $process.Kill($true)
                $null = $process.WaitForExit(2000)
                $killed.Add($processId)
            } finally {
                $process.Dispose()
            }
        } catch {
            Write-Verbose "Process $processId was not ended: $($_.Exception.Message)"
        }
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return , $killed.ToArray()
}

function Register-WorkloadMaskSink {
    <#
    .SYNOPSIS
        Sets the one sink that hands secret values to the front end; $null removes it.
    .DESCRIPTION
        A sink takes one [string[]] argument and writes exactly one [bool].
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][AllowNull()][scriptblock]$ScriptBlock)
    $script:MaskSink = $ScriptBlock
}

function Send-WorkloadMask {
    <#
    .SYNOPSIS
        Hands secret values to the registered sink; returns whether it accepted them.
    .DESCRIPTION
        $true without a sink, or when every value is empty. The non-empty values
        travel as one array argument: .Invoke() and splatting would spread them
        over the sink's parameters.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Value)
    if ($null -eq $script:MaskSink) { return $true }
    $nonEmpty = [string[]]@($Value | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($nonEmpty.Count -eq 0) { return $true }
    return [bool](& $script:MaskSink ([string[]]$nonEmpty))
}

function Get-WorkloadCollapsedText {
    # Private: control characters as spaces, white space runs as one space, trimmed.
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $plain = [regex]::Replace($Text, '\p{Cc}', ' ')
    return ([regex]::Replace($plain, '\s+', ' ')).Trim()
}

function ConvertTo-WorkloadQuotedText {
    <#
    .SYNOPSIS
        Text as one double-quoted token of the snapshot grammar.
    .DESCRIPTION
        Control characters become spaces, white space runs collapse, the text is
        trimmed, then a backslash is written \\ and a double quote \".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $collapsed = Get-WorkloadCollapsedText -Text $Text
    return '"' + $collapsed.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-WorkloadSegmentValue {
    # Private: one field of an OCR segment, a hashtable or an object.
    param($Segment, [Parameter(Mandatory)][string]$Name)
    if ($Segment -is [System.Collections.IDictionary]) {
        if ($Segment.Contains($Name)) { return $Segment[$Name] }
        return $null
    }
    $property = $Segment.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-WorkloadScreenSnapshot {
    <#
    .SYNOPSIS
        The text of a screen snapshot and its reference table, from OCR segments.
    .DESCRIPTION
        Each segment of Get-OcrWordBoxLine is one line entry with the reference
        s<ReferenceBase + k> and its box, whatever the filter or the limits hide,
        so a filtered or cut view never changes what a reference means. A line
        that only another OCR engine read is appended as a text entry without a
        reference. FileText holds every entry, cut only at MaxSnapshotFileChars;
        InlineText holds the entries that contain Find (ordinal, case ignored),
        cut at MaxSnapshotInlineEntries or MaxSnapshotInlineChars. A cut view ends
        with the line '# truncated: shown=<n> entries=<m>'. Pure: it reads no
        file and no clock.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Line,
        [AllowNull()][System.Collections.IDictionary]$OtherText,
        [AllowEmptyString()][string]$VmName,
        [AllowEmptyString()][string]$FrameName,
        [int]$Ordinal,
        [long]$ReferenceBase,
        [AllowEmptyString()][AllowNull()][string]$Find
    )
    $limit = Get-WorkloadProtocolLimit
    $segments = @($Line | Where-Object { $null -ne $_ })
    $header = '# surface: screen   snapshot: {0}   vm: {1}   frame: {2}' -f $Ordinal, $VmName, $FrameName
    if (-not [string]::IsNullOrEmpty($Find)) { $header += '   find: ' + (ConvertTo-WorkloadQuotedText -Text $Find) }
    if ($segments.Count -eq 0) { $header += '   locator: none' }

    $table = [ordered]@{}
    $entries = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $k = 0
    foreach ($segment in $segments) {
        $k++
        $id = 's' + ($ReferenceBase + $k)
        $text = [string](Get-WorkloadSegmentValue -Segment $segment -Name 'text')
        $x = [int](Get-WorkloadSegmentValue -Segment $segment -Name 'x')
        $y = [int](Get-WorkloadSegmentValue -Segment $segment -Name 'y')
        $w = [int](Get-WorkloadSegmentValue -Segment $segment -Name 'w')
        $h = [int](Get-WorkloadSegmentValue -Segment $segment -Name 'h')
        $table[$id] = @{
            Text    = $text
            X       = $x
            Y       = $y
            W       = $w
            H       = $h
            Block   = Get-WorkloadSegmentValue -Segment $segment -Name 'block'
            Par     = Get-WorkloadSegmentValue -Segment $segment -Name 'par'
            Line    = Get-WorkloadSegmentValue -Segment $segment -Name 'line'
            Segment = Get-WorkloadSegmentValue -Segment $segment -Name 'segment'
        }
        $collapsed = Get-WorkloadCollapsedText -Text $text
        $null = $seen.Add($collapsed.ToLowerInvariant())
        $entries.Add(@{
                Text  = $collapsed
                Entry = ('- line {0} [ref={1}] [box={2},{3},{4},{5}]' -f (ConvertTo-WorkloadQuotedText -Text $text), $id, $x, $y, $w, $h)
            })
    }
    if ($null -ne $OtherText) {
        foreach ($provider in @($OtherText.Keys)) {
            if ([string]$provider -eq 'tesseract') { continue }
            $providerText = [string]$OtherText[$provider]
            if ([string]::IsNullOrEmpty($providerText)) { continue }
            foreach ($rawLine in ($providerText -split "`r?`n")) {
                $collapsed = Get-WorkloadCollapsedText -Text $rawLine
                if ($collapsed.Length -eq 0) { continue }
                if (-not $seen.Add($collapsed.ToLowerInvariant())) { continue }
                $entries.Add(@{
                        Text  = $collapsed
                        Entry = ('- text {0} [engine={1}]' -f (ConvertTo-WorkloadQuotedText -Text $rawLine), $provider)
                    })
            }
        }
    }

    $file = [System.Text.StringBuilder]::new()
    $null = $file.Append($header)
    $fileShown = 0
    foreach ($entry in $entries) {
        if ($file.Length + 1 + $entry.Entry.Length -gt $limit.MaxSnapshotFileChars) { break }
        $null = $file.Append("`n").Append($entry.Entry)
        $fileShown++
    }
    if ($fileShown -lt $entries.Count) {
        $null = $file.Append("`n").Append(('# truncated: shown={0} entries={1}' -f $fileShown, $entries.Count))
    }

    $selected = @(foreach ($entry in $entries) {
            if ([string]::IsNullOrEmpty($Find) -or $entry.Text.Contains($Find, [StringComparison]::OrdinalIgnoreCase)) { $entry }
        })
    $inline = [System.Text.StringBuilder]::new()
    $null = $inline.Append($header)
    $shown = 0
    foreach ($entry in $selected) {
        if ($shown + 1 -gt $limit.MaxSnapshotInlineEntries) { break }
        if ($inline.Length + 1 + $entry.Entry.Length -gt $limit.MaxSnapshotInlineChars) { break }
        $null = $inline.Append("`n").Append($entry.Entry)
        $shown++
    }
    if ($shown -lt $selected.Count) {
        $null = $inline.Append("`n").Append(('# truncated: shown={0} entries={1}' -f $shown, $selected.Count))
    }

    return @{
        InlineText    = $inline.ToString()
        FileText      = $file.ToString()
        Entries       = $selected.Count
        Shown         = $shown
        Truncated     = ($shown -lt $selected.Count)
        Table         = $table
        ReferenceBase = $ReferenceBase + $segments.Count
    }
}

function ConvertTo-WorkloadPageSnapshot {
    <#
    .SYNOPSIS
        The text of a page snapshot and its reference table, from display entries.
    .DESCRIPTION
        The page form of ConvertTo-WorkloadScreenSnapshot, with the same limits,
        counts and truncation line. Each node entry with an address gets the
        reference p<ReferenceBase + k> whatever the filter or the limits hide;
        a text entry has none. The table keeps the role, the name, the address
        and the page generation of each reference, so a later suggestion can
        tell that the page navigated. Pure: it reads no file and no clock.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Entry,
        [AllowEmptyString()][AllowNull()][string]$Url,
        [AllowEmptyString()][AllowNull()][string]$Title,
        [int]$Generation,
        [int]$Ordinal,
        [long]$ReferenceBase,
        [AllowEmptyString()][AllowNull()][string]$Find
    )
    $limit = Get-WorkloadProtocolLimit
    $header = '# surface: page   snapshot: {0}   url: {1}   title: {2}' -f $Ordinal, (Get-WorkloadCollapsedText -Text $Url), (Get-WorkloadCollapsedText -Text $Title)
    if (-not [string]::IsNullOrEmpty($Find)) { $header += '   find: ' + (ConvertTo-WorkloadQuotedText -Text $Find) }

    $table = [ordered]@{}
    $entries = [Collections.Generic.List[object]]::new()
    $k = 0
    foreach ($item in @($Entry | Where-Object { $null -ne $_ })) {
        $name = [string](Get-WorkloadSegmentValue -Segment $item -Name 'Name')
        $indent = '  ' * [Math]::Max(0, [int](Get-WorkloadSegmentValue -Segment $item -Name 'Indent'))
        if ([string](Get-WorkloadSegmentValue -Segment $item -Name 'Kind') -ceq 'text') {
            $line = $indent + '- text ' + (ConvertTo-WorkloadQuotedText -Text $name)
        } else {
            $role = [string](Get-WorkloadSegmentValue -Segment $item -Name 'Role')
            $line = $indent + '- ' + $role
            if (-not [string]::IsNullOrEmpty((Get-WorkloadCollapsedText -Text $name))) { $line += ' ' + (ConvertTo-WorkloadQuotedText -Text $name) }
            foreach ($tag in @(Get-WorkloadSegmentValue -Segment $item -Name 'Tags')) {
                if (-not [string]::IsNullOrEmpty([string]$tag)) { $line += ' [' + [string]$tag + ']' }
            }
            $address = Get-WorkloadSegmentValue -Segment $item -Name 'Address'
            if ($null -ne $address) {
                $k++
                $id = 'p' + ($ReferenceBase + $k)
                $table[$id] = @{ Role = $role; Name = $name; Address = $address; Generation = $Generation }
                $line += ' [ref=' + $id + ']'
            }
        }
        $entries.Add(@{ Text = (Get-WorkloadCollapsedText -Text $name); Entry = $line })
    }

    $file = [System.Text.StringBuilder]::new()
    $null = $file.Append($header)
    $fileShown = 0
    foreach ($item in $entries) {
        if ($file.Length + 1 + $item.Entry.Length -gt $limit.MaxSnapshotFileChars) { break }
        $null = $file.Append("`n").Append($item.Entry)
        $fileShown++
    }
    if ($fileShown -lt $entries.Count) {
        $null = $file.Append("`n").Append(('# truncated: shown={0} entries={1}' -f $fileShown, $entries.Count))
    }

    $selected = @(foreach ($item in $entries) {
            if ([string]::IsNullOrEmpty($Find) -or $item.Text.Contains($Find, [StringComparison]::OrdinalIgnoreCase)) { $item }
        })
    $inline = [System.Text.StringBuilder]::new()
    $null = $inline.Append($header)
    $shown = 0
    foreach ($item in $selected) {
        if ($shown + 1 -gt $limit.MaxSnapshotInlineEntries) { break }
        if ($inline.Length + 1 + $item.Entry.Length -gt $limit.MaxSnapshotInlineChars) { break }
        $null = $inline.Append("`n").Append($item.Entry)
        $shown++
    }
    if ($shown -lt $selected.Count) {
        $null = $inline.Append("`n").Append(('# truncated: shown={0} entries={1}' -f $shown, $selected.Count))
    }

    return @{
        InlineText    = $inline.ToString()
        FileText      = $file.ToString()
        Entries       = $selected.Count
        Shown         = $shown
        Truncated     = ($shown -lt $selected.Count)
        Table         = $table
        ReferenceBase = $ReferenceBase + $k
    }
}

Export-ModuleMember -Function Get-WorkloadProtocolLimit, ConvertTo-WorkloadFrameLine, ConvertFrom-WorkloadFrameLine, `
    Test-WorkloadOperationId, Get-WorkloadInputHash, Test-WorkloadProcessIdentity, `
    Register-WorkloadOwnedProcess, Unregister-WorkloadOwnedProcess, Invoke-WorkloadOwnedProcessCleanup, `
    Register-WorkloadMaskSink, Send-WorkloadMask, ConvertTo-WorkloadQuotedText, ConvertTo-WorkloadScreenSnapshot, `
    ConvertTo-WorkloadPageSnapshot
