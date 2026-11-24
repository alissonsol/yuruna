<#PSScriptInfo
.VERSION 2026.11.23
.GUID 420d8d85-e68a-45ab-a533-01961fd6a672
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload sequence save
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

# The YAML of an authored step and the sequence file a workload session saves.
# One serializer writes both the step text a session shows and the file it
# saves, so what an author reads is what replays. A saved file is checked as
# the gates and the reader will see it (round trip, schema, header, chain)
# before it is published, and it is published with a hard link, which never
# replaces a file another writer created in between. The planner and the
# engine are called by name: importing them here would reload the engine.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../tools/Source.Identity.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.LocalizationExchange.psm1') -DisableNameChecking

$script:WorkloadSaveTool = 'workload_save_sequence'
$script:WorkloadSequenceNamePattern = '^workload\.[a-z0-9]+(?:[.-][a-z0-9]+)*$'
$script:WorkloadResourceNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$'
$script:WorkloadStepKeyPattern = '^[A-Za-z][A-Za-z0-9_]*$'
$script:WorkloadBareWordPattern = '^[A-Za-z][A-Za-z0-9]*$'
# Plain words a YAML reader takes for a boolean or a null.
$script:WorkloadYamlReservedWord = @('true', 'false', 'yes', 'no', 'on', 'off', 'null', 'y', 'n')
$script:WorkloadHostSuffix = @('ubuntu.kvm', 'windows.hyper-v', 'macos.utm')
$script:WorkloadMaxStepDepth = 8
# Whole doubles below 2^63 are written as the long they hold.
$script:WorkloadLongLimit = 9.2233720368547758E18
$script:WorkloadTempPattern = '^.+\.yml\.\d+-[0-9a-f]{32}\.tmp$'

function ConvertTo-WorkloadYamlScalar {
    <#
    .SYNOPSIS
        One value as a YAML scalar that reads back as the same value.
    .DESCRIPTION
        A string is written as an ASCII JSON string, which is a YAML
        double-quoted scalar; with -Bare a plain word that YAML cannot take
        for a boolean or a null is written without quotes. A whole double is
        written as the long it holds, because powershell-yaml reads 1E+20 as a
        BigInteger and 1.5E-05 as a Decimal: a text with an exponent would not
        read back. Any other type, $null, NaN and an infinity throw.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Value,
        [switch]$Bare
    )
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { throw [System.ArgumentException]::new('a null value has no scalar form') }
    if ($Value -is [string]) {
        if ($Bare -and $Value -cmatch $script:WorkloadBareWordPattern -and $script:WorkloadYamlReservedWord -notcontains $Value.ToLowerInvariant()) {
            return $Value
        }
        $json = ConvertTo-Json -InputObject $Value -Compress -EscapeHandling EscapeNonAscii
        return $json.Replace([string][char]0x7F, '\u007F')
    }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [byte] -or
        $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [System.Numerics.BigInteger]) {
        return $Value.ToString($culture)
    }
    if ($Value -is [decimal]) { return $Value.ToString($culture) }
    if ($Value -is [double] -or $Value -is [single]) {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            throw [System.ArgumentException]::new('NaN or an infinity has no scalar form')
        }
        if ([Math]::Truncate($number) -eq $number -and [Math]::Abs($number) -lt $script:WorkloadLongLimit) {
            return ([long]$number).ToString($culture)
        }
        $text = $number.ToString('R', $culture)
        if ($text.Contains('E')) { throw [System.ArgumentException]::new("the number $text needs an exponent") }
        return $text
    }
    throw [System.ArgumentException]::new("a value of type $($Value.GetType().FullName) has no scalar form")
}

function Test-WorkloadListValue {
    # Private: an enumerable that is neither a string nor a dictionary.
    [OutputType([bool])]
    param($Value)
    return ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary])
}

function Get-WorkloadMappingLine {
    # Private: the lines of a block mapping; Prefix is written before the first key.
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory)][int]$Indent,
        [Parameter(Mandatory)][int]$Depth,
        [string]$FirstPrefix = '',
        [switch]$StepLevel
    )
    if ($Depth -gt $script:WorkloadMaxStepDepth) { throw [System.ArgumentException]::new("a step nests deeper than $($script:WorkloadMaxStepDepth) levels") }
    $lines = [Collections.Generic.List[string]]::new()
    $pad = ' ' * $Indent
    $first = $true
    foreach ($key in @($Map.Keys)) {
        $keyText = [string]$key
        if ($keyText -cnotmatch $script:WorkloadStepKeyPattern) { throw [System.ArgumentException]::new("the key '$keyText' cannot be written") }
        $lead = if ($first) { $pad + $FirstPrefix } else { $pad + (' ' * $FirstPrefix.Length) }
        $first = $false
        $value = $Map[$key]
        $inner = $Indent + $FirstPrefix.Length
        if ($value -is [System.Collections.IDictionary]) {
            if ($value.Count -eq 0) { $lines.Add("${lead}${keyText}: {}"); continue }
            $lines.Add("${lead}${keyText}:")
            foreach ($line in (Get-WorkloadMappingLine -Map $value -Indent ($inner + 2) -Depth ($Depth + 1))) { $lines.Add($line) }
            continue
        }
        if (Test-WorkloadListValue -Value $value) {
            $items = @($value)
            if ($items.Count -eq 0) { $lines.Add("${lead}${keyText}: []"); continue }
            $maps = @($items | Where-Object { $_ -is [System.Collections.IDictionary] })
            if ($maps.Count -eq $items.Count) {
                if ($Depth + 1 -gt $script:WorkloadMaxStepDepth) { throw [System.ArgumentException]::new("a step nests deeper than $($script:WorkloadMaxStepDepth) levels") }
                $lines.Add("${lead}${keyText}:")
                foreach ($item in $items) {
                    foreach ($line in (Get-WorkloadMappingLine -Map $item -Indent ($inner + 2) -Depth ($Depth + 2) -FirstPrefix '- ')) { $lines.Add($line) }
                }
                continue
            }
            if ($maps.Count -gt 0) { throw [System.ArgumentException]::new("the list '$keyText' mixes maps and values") }
            $scalars = @(foreach ($item in $items) {
                    if (Test-WorkloadListValue -Value $item) { throw [System.ArgumentException]::new("the list '$keyText' holds a list") }
                    ConvertTo-WorkloadYamlScalar -Value $item
                })
            $lines.Add("${lead}${keyText}: [" + ($scalars -join ', ') + ']')
            continue
        }
        $bare = $StepLevel -and ($keyText -ceq 'action' -or $keyText -ceq 'on')
        $lines.Add("${lead}${keyText}: " + (ConvertTo-WorkloadYamlScalar -Value $value -Bare:$bare))
    }
    return , ([string[]]$lines.ToArray())
}

function ConvertTo-WorkloadStepText {
    <#
    .SYNOPSIS
        The YAML lines of one step as a list item, keys in the order of the map.
    .DESCRIPTION
        The first line starts with '- ' and the other keys align under its
        first key. The values of action and on are written bare. A list of
        values is a flow sequence, a list of maps a block sequence and a map a
        block mapping, each two spaces deeper; nesting deeper than eight
        levels, a key that is not a plain name and a value of another type
        throw.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step,
        [ValidateRange(0, 64)][int]$Indent = 0
    )
    return , (Get-WorkloadMappingLine -Map $Step -Indent $Indent -Depth 1 -FirstPrefix '- ' -StepLevel)
}

function Get-WorkloadStepListLine {
    # Private: the region, the key and the items of one step list of a sequence file.
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyCollection()][AllowNull()][object[]]$Step)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# --- REGION: $Key")
    $items = @($Step | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        $lines.Add("${Key}: []")
    } else {
        $lines.Add("${Key}:")
        foreach ($item in $items) {
            foreach ($line in (ConvertTo-WorkloadStepText -Step $item -Indent 2)) { $lines.Add($line) }
        }
    }
    return , ([string[]]$lines.ToArray())
}

function ConvertTo-WorkloadSequenceText {
    <#
    .SYNOPSIS
        The text of a saved guest sequence: header, identity, resource chain, variables and steps.
    .DESCRIPTION
        LF line ends, one final LF, no trailing spaces, pure ASCII. The header
        holds the license pointer above the copyright line and the
        sequenceGuid, which the metadata gate reads in the first 40 lines. An
        empty variable map is left out, a $null variable is never written, and
        an empty step list is written as [] under its region line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][ValidateSet('gui', 'ssh')][string]$KeystrokeMechanism,
        [Parameter(Mandatory)][string]$OsKey,
        [Parameter(Mandatory)][string[]]$Resource,
        [AllowNull()][System.Collections.IDictionary]$Variables,
        [AllowEmptyCollection()][AllowNull()][System.Collections.IDictionary[]]$ComponentStep,
        [AllowEmptyCollection()][AllowNull()][System.Collections.IDictionary[]]$WorkloadStep,
        [Parameter(Mandatory)][string]$SequenceGuid,
        [Parameter(Mandatory)][int]$Year
    )
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# yaml-language-server: $schema=../schemas/sequence.schema.yml')
    $lines.Add('')
    $lines.Add('# LICENSEURI https://yuruna.link/license')
    $lines.Add("# Copyright (c) 2019-$Year by Alisson Sol et al.")
    $lines.Add('')
    $lines.Add("sequenceGuid: $SequenceGuid")
    $lines.Add('sequenceRevision: 1')
    $lines.Add('')
    $lines.Add('description: ' + (ConvertTo-WorkloadYamlScalar -Value $Description))
    $lines.Add("keystrokeMechanism: $KeystrokeMechanism")
    $lines.Add('')
    $lines.Add('# --- REGION: resource')
    $lines.Add('resource:')
    $lines.Add("  ${OsKey}:")
    foreach ($name in $Resource) { $lines.Add('    - ' + (ConvertTo-WorkloadYamlScalar -Value $name)) }
    $written = @()
    if ($null -ne $Variables) { $written = @($Variables.Keys | Where-Object { $null -ne $Variables[$_] }) }
    if ($written.Count -gt 0) {
        $lines.Add('variables:')
        foreach ($key in $written) {
            $keyText = [string]$key
            if ($keyText -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $keyText = ConvertTo-WorkloadYamlScalar -Value $keyText }
            $lines.Add("  ${keyText}: " + (ConvertTo-WorkloadYamlScalar -Value $Variables[$key]))
        }
    }
    $lines.Add('')
    foreach ($line in (Get-WorkloadStepListLine -Key 'component' -Step $ComponentStep)) { $lines.Add($line) }
    $lines.Add('')
    foreach ($line in (Get-WorkloadStepListLine -Key 'workload' -Step $WorkloadStep)) { $lines.Add($line) }
    return (($lines | ForEach-Object { $_.TrimEnd() }) -join "`n") + "`n"
}

function Test-WorkloadPathOccupied {
    # Private: a file, a directory or a link of any kind, dangling included, holds the name.
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { return $true }
    try {
        return ($null -ne [IO.FileInfo]::new($Path).LinkTarget)
    } catch {
        Write-Verbose "The name '$Path' cannot be inspected: $($_.Exception.Message)"
        return $true
    }
}

function Test-WorkloadSamePath {
    # Private: two canonical paths compare ordinally on Linux and ignoring case elsewhere.
    [OutputType([bool])]
    param([string]$Left, [string]$Right)
    $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    return [string]::Equals($Left.TrimEnd('/', '\'), $Right.TrimEnd('/', '\'), $comparison)
}

function Get-WorkloadCanonicalFolder {
    # Private: the canonical framework sequence folder, or the refusal for one outside the checkout.
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$SequencesDir)
    $folder = Resolve-YurunaCanonicalPath -Path $SequencesDir
    $root = Resolve-YurunaCanonicalPath -Path $RepoRoot
    $expected = if ($root.Resolved) { Join-Path (Join-Path ([string]$root.Path) 'test') 'sequences' } else { '' }
    if (-not $folder.Resolved -or -not $root.Resolved -or -not (Test-WorkloadSamePath -Left ([string]$folder.Path) -Right $expected)) {
        return @{
            Path    = $null
            Refusal = (New-WorkloadRefusal -Code 'workload_folder_outside' -Key 'runner.workload_folder_outside' -Arguments @{
                    tool = $script:WorkloadSaveTool; folder = $SequencesDir; resolved = [string]$folder.Path })
        }
    }
    return @{ Path = [string]$folder.Path; Refusal = $null }
}

function Resolve-WorkloadSequenceDestination {
    <#
    .SYNOPSIS
        Where a saved sequence goes, or the refusal that keeps it from being written.
    .DESCRIPTION
        A sequence is always written to the framework's test/sequences: a
        project test folder is a clone whenever repositories.projectUrl is set.
        The folder must resolve inside the checkout, and the name must be free
        in every search folder, for the plain file and for every host variant:
        a duplicate in two project folders would make the name a planner
        failure, and a host variant would shadow the new file on that host.
    #>
    [CmdletBinding()]
    [OutputType([hashtable], [System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name
    )
    $searchFolders = [Collections.Generic.List[string]]::new()
    $searchFolders.Add($SequencesDir)
    foreach ($folder in @(Get-ProjectFlatTestSearchDir -RepoRoot $RepoRoot)) { if ($folder) { $searchFolders.Add([string]$folder) } }
    $canonical = Get-WorkloadCanonicalFolder -RepoRoot $RepoRoot -SequencesDir $SequencesDir
    if ($null -ne $canonical.Refusal) { return $canonical.Refusal }
    $fileNames = @("$Name.yml") + @($script:WorkloadHostSuffix | ForEach-Object { "$Name.$_.yml" })
    foreach ($folder in $searchFolders) {
        foreach ($fileName in $fileNames) {
            $candidate = Join-Path $folder $fileName
            if (Test-WorkloadPathOccupied -Path $candidate) {
                return (New-WorkloadRefusal -Code 'workload_name_exists' -Key 'runner.workload_name_exists' -Arguments @{
                        tool = $script:WorkloadSaveTool; name = $Name; path = $candidate })
            }
        }
    }
    return @{
        Folder         = $SequencesDir
        RelativeFolder = 'test/sequences'
        FinalPath      = (Join-Path $SequencesDir "$Name.yml")
        SearchFolders  = [string[]]$searchFolders.ToArray()
        CanonicalPath  = $canonical.Path
    }
}

function Publish-WorkloadSequenceFile {
    <#
    .SYNOPSIS
        Gives a written candidate its final name without ever replacing a file.
    .DESCRIPTION
        A hard link fails when the name exists, on every platform; a rename
        without overwrite does not on Linux and macOS, where it checks and
        renames in two steps. Nothing is copied, so a file system without hard
        links fails the publish. A temporary name that cannot be removed after
        the link leaves the publish done; the next save sweeps it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$TempPath,
        [Parameter(Mandatory)][string]$FinalPath
    )
    $result = @{ Published = $false; Reason = ''; Detail = '' }
    try {
        New-Item -ItemType HardLink -Path $FinalPath -Value $TempPath -ErrorAction Stop | Out-Null
        $result.Published = $true
    } catch {
        if (Test-WorkloadPathOccupied -Path $FinalPath) {
            $result.Reason = 'exists'
        } else {
            $result.Reason = 'failed'
            $result.Detail = $_.Exception.Message
        }
    }
    if ($result.Published) {
        try {
            Remove-Item -LiteralPath $TempPath -Force -ErrorAction Stop
        } catch {
            Write-Verbose "The temporary name '$TempPath' stays until the next save: $($_.Exception.Message)"
        }
    }
    return $result
}

function ConvertTo-WorkloadIntendedValue {
    # Private: a copy of a value as the saved file states it (a whole double as its long).
    param($Value)
    if ($Value -is [double] -or $Value -is [single]) {
        $number = [double]$Value
        if (-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and
            [Math]::Truncate($number) -eq $number -and [Math]::Abs($number) -lt $script:WorkloadLongLimit) {
            return [long]$number
        }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) { $copy[$key] = ConvertTo-WorkloadIntendedValue -Value $Value[$key] }
        return , $copy
    }
    if (Test-WorkloadListValue -Value $Value) {
        return , ([object[]]@(foreach ($item in $Value) { , (ConvertTo-WorkloadIntendedValue -Value $item) }))
    }
    return $Value
}

function Get-WorkloadDeclaredGuid {
    # Private: every sequenceGuid the YAML files of the search folders declare.
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([string[]]$Folder)
    $declared = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Folder) {
        if (-not (Test-Path -LiteralPath $item -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $item -Filter '*.yml' -File -ErrorAction SilentlyContinue)) {
            $text = ''
            try { $text = [IO.File]::ReadAllText($file.FullName) } catch { Write-Verbose "'$($file.FullName)' was not read: $($_.Exception.Message)"; continue }
            foreach ($match in [regex]::Matches($text, '(?m)^\s*sequenceGuid:\s*["'']?([0-9A-Fa-f-]{36})')) { $null = $declared.Add($match.Groups[1].Value) }
        }
    }
    return , $declared
}

function Remove-WorkloadStaleCandidate {
    # Private: delete temporary candidates older than one hour; one another process holds is skipped.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Deletes temporary candidates an earlier save left behind.')]
    param([Parameter(Mandatory)][string]$Folder, [datetime]$NowUtc = [DateTime]::UtcNow)
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -cnotmatch $script:WorkloadTempPattern) { continue }
        if ($file.LastWriteTimeUtc -gt $NowUtc.AddHours(-1)) { continue }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        } catch {
            Write-Verbose "The stale candidate '$($file.FullName)' was skipped: $($_.Exception.Message)"
        }
    }
}

function New-WorkloadCandidateRefusal {
    # Private: the refusal of one check of the generated sequence.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a value; changes nothing.')]
    param([Parameter(Mandatory)][string]$Check, [AllowEmptyString()][string]$Message)
    return (New-WorkloadRefusal -Code 'workload_candidate_invalid' -Key 'runner.workload_candidate_invalid' -Arguments @{
            tool = $script:WorkloadSaveTool; check = $Check; message = $Message })
}

function Save-WorkloadSequenceFile {
    <#
    .SYNOPSIS
        Writes the runnable steps of a session's journal as a guest sequence file.
    .DESCRIPTION
        The file goes to the framework's test/sequences under a name that is
        free in every search folder. It is composed, read back, checked against
        the schema and the header rules, searched for a registered secret,
        written under a temporary name, read and planned as the runner will,
        and only then published with a hard link. Failed, canceled and replay
        entries are not saved; they are listed under excluded. A throw of the
        canonical-path check or of the publish leaves the function after its
        cleanup, and the worker answers it as an internal error.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [AllowEmptyCollection()][AllowNull()][object[]]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Resource,
        [int]$ComponentCount = 0
    )
    $tool = $script:WorkloadSaveTool
    $prefix = "workload.$($Session.GuestKey)."
    $badEnding = @('.yml', '.yaml') + @($script:WorkloadHostSuffix | ForEach-Object { ".$_" })
    $endsBadly = @($badEnding | Where-Object { $Name.EndsWith($_, [StringComparison]::Ordinal) }).Count -gt 0
    if ($Name.Contains("`n") -or $Name -cnotmatch $script:WorkloadSequenceNamePattern -or $Name.Length -gt 100 -or
        -not $Name.StartsWith($prefix, [StringComparison]::Ordinal) -or $endsBadly) {
        return (New-WorkloadRefusal -Code 'workload_name_invalid' -Key 'runner.workload_name_invalid' -Arguments @{
                tool = $tool; name = $Name; pattern = $script:WorkloadSequenceNamePattern; prefix = $prefix })
    }
    if ($Description.Length -lt 1 -or $Description.Length -gt 200 -or $Description -match '[\x00-\x1F\x7F]') {
        return (New-WorkloadRefusal -Code 'workload_argument_invalid' -Key 'runner.workload_argument_invalid' -Arguments @{
                tool = $tool; name = 'description'; pattern = 'one line of 1 to 200 characters without control characters' })
    }
    $keystroke = if ($Name.EndsWith('.ssh', [StringComparison]::Ordinal)) { 'ssh' } else { 'gui' }

    $steps = [Collections.Generic.List[System.Collections.IDictionary]]::new()
    $excluded = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Journal | Where-Object { $null -ne $_ })) {
        if ($entry['runnable'] -eq $true) {
            $steps.Add([System.Collections.IDictionary]$entry['authored'])
        } else {
            $excluded.Add([ordered]@{ seq = $entry['seq']; operationId = $entry['operationId']; tool = $entry['tool']; outcome = $entry['outcome']; effect = $entry['effect'] })
        }
    }
    if ($steps.Count -eq 0) {
        return (New-WorkloadRefusal -Code 'workload_journal_empty' -Key 'runner.workload_journal_empty' -Arguments @{ tool = $tool })
    }
    if ($ComponentCount -lt 0 -or $ComponentCount -gt $steps.Count) {
        return (New-WorkloadRefusal -Code 'workload_split_invalid' -Key 'runner.workload_split_invalid' -Arguments @{ tool = $tool; value = $ComponentCount; count = $steps.Count })
    }
    $componentSteps = [System.Collections.IDictionary[]]@($steps | Select-Object -First $ComponentCount)
    $workloadSteps = [System.Collections.IDictionary[]]@($steps | Select-Object -Skip $ComponentCount)

    $resourceValid = $Resource.Count -ge 1 -and $Resource.Count -le 16
    foreach ($item in $Resource) {
        if ($null -eq $item -or $item.Contains("`n") -or $item -cnotmatch $script:WorkloadResourceNamePattern) { $resourceValid = $false }
    }
    if (-not $resourceValid) {
        return (New-WorkloadRefusal -Code 'workload_resource_invalid' -Key 'runner.workload_resource_invalid' -Arguments @{ tool = $tool; pattern = $script:WorkloadResourceNamePattern })
    }

    $variables = [ordered]@{}
    if ($Session.SourceVariables -is [System.Collections.IDictionary]) {
        foreach ($key in @($Session.SourceVariables.Keys)) { $variables[$key] = $Session.SourceVariables[$key] }
    }
    if ($Session.OverrideVariables -is [System.Collections.IDictionary]) {
        foreach ($key in @($Session.OverrideVariables.Keys)) { $variables[$key] = $Session.OverrideVariables[$key] }
    }
    foreach ($key in @($variables.Keys)) { if ($null -eq $variables[$key]) { $variables.Remove($key) } }

    $destination = Resolve-WorkloadSequenceDestination -RepoRoot $Session.RepoRoot -SequencesDir $Session.SequencesDir -Name $Name
    if ($destination.Contains('ok') -and $destination['ok'] -eq $false) { return $destination }

    $declared = Get-WorkloadDeclaredGuid -Folder $destination.SearchFolders
    $sequenceGuid = $null
    for ($draw = 0; $draw -lt 8; $draw++) {
        $candidateGuid = [string](New-SourceGuid)
        if (-not $declared.Contains($candidateGuid)) { $sequenceGuid = $candidateGuid; break }
    }
    if ($null -eq $sequenceGuid) { return (New-WorkloadCandidateRefusal -Check 'guid' -Message 'eight generated values were already declared.') }

    $text = $null
    try {
        $text = ConvertTo-WorkloadSequenceText -Description $Description -KeystrokeMechanism $keystroke -OsKey $Session.OsKey -Resource $Resource `
            -Variables $variables -ComponentStep $componentSteps -WorkloadStep $workloadSteps -SequenceGuid $sequenceGuid -Year ([DateTime]::UtcNow.Year)
    } catch {
        return (New-WorkloadCandidateRefusal -Check 'value-type' -Message $_.Exception.Message)
    }

    $parsed = $null
    try {
        $parsed = ConvertFrom-Yaml -Yaml $text -Ordered
    } catch {
        return (New-WorkloadCandidateRefusal -Check 'round-trip' -Message $_.Exception.Message)
    }
    $intended = [ordered]@{
        sequenceGuid       = $sequenceGuid
        sequenceRevision   = 1
        description        = $Description
        keystrokeMechanism = $keystroke
        resource           = [ordered]@{ ([string]$Session.OsKey) = [object[]]@($Resource) }
    }
    if ($variables.Count -gt 0) { $intended['variables'] = ConvertTo-WorkloadIntendedValue -Value $variables }
    $intended['component'] = ConvertTo-WorkloadIntendedValue -Value ([object[]]$componentSteps)
    $intended['workload'] = ConvertTo-WorkloadIntendedValue -Value ([object[]]$workloadSteps)
    $parsedJson = ConvertTo-Json -InputObject $parsed -Depth 32 -Compress
    $intendedJson = ConvertTo-Json -InputObject $intended -Depth 32 -Compress
    if (-not [string]::Equals($parsedJson, $intendedJson, [StringComparison]::Ordinal)) {
        return (New-WorkloadCandidateRefusal -Check 'round-trip' -Message 'the file does not read back as the steps it was written from.')
    }
    $schemaPath = Join-Path ([string]$Session.TestRoot) 'schemas/sequence.schema.yml'
    $schemaError = $null
    try {
        $schemaJson = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($schemaPath)) -Ordered | ConvertTo-Json -Depth 32
        $schemaError = Get-YurunaJsonSchemaError -Json (ConvertTo-Json -InputObject $parsed -Depth 32) -Schema $schemaJson
    } catch {
        $schemaError = $_.Exception.Message
    }
    if ($schemaError) { return (New-WorkloadCandidateRefusal -Check 'schema' -Message ([string]$schemaError)) }
    $header = Get-SourceHeaderFact -Style hash -Line @($text.Split("`n") | Select-Object -First 40) -RelativePath "$Name.yml"
    if (-not ($header.Copyright -and $header.Pointer -and $header.GuestSequence -and $header.SequenceGuid -ceq $sequenceGuid -and
            -not $header.LineGuid -and $header.StrayGuidLine -eq 0)) {
        return (New-WorkloadCandidateRefusal -Check 'header' -Message 'the header lacks a fact the metadata gate reads.')
    }

    if (Test-SequenceSecretText -Text $text) {
        return (New-WorkloadRefusal -Code 'workload_secret_found' -Key 'runner.workload_secret_found' -Arguments @{ tool = $tool })
    }

    $finalPath = [string]$destination.FinalPath
    $tmp = '{0}.{1}-{2}.tmp' -f $finalPath, $PID, [guid]::NewGuid().ToString('N')
    Remove-WorkloadStaleCandidate -Folder $destination.Folder
    $stream = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }

    $published = $false
    try {
        try {
            $null = Read-SequenceFile -Path $tmp -NoCache
        } catch {
            return (New-WorkloadCandidateRefusal -Check 'read' -Message $_.Exception.Message)
        }
        try {
            $null = Resolve-NamedSequenceChain -RepoRoot $Session.RepoRoot -SequencesDir $Session.SequencesDir -HostType $Session.HostType `
                -SequenceName $Name -OsKey $Session.OsKey -TopLevelPath $tmp
        } catch {
            return (New-WorkloadCandidateRefusal -Check 'chain' -Message $_.Exception.Message)
        }
        $again = Get-WorkloadCanonicalFolder -RepoRoot $Session.RepoRoot -SequencesDir $Session.SequencesDir
        if ($null -ne $again.Refusal) { return $again.Refusal }
        if (-not (Test-WorkloadSamePath -Left $again.Path -Right ([string]$destination.CanonicalPath))) {
            return (New-WorkloadRefusal -Code 'workload_folder_outside' -Key 'runner.workload_folder_outside' -Arguments @{
                    tool = $tool; folder = [string]$Session.SequencesDir; resolved = [string]$again.Path })
        }
        $publish = Publish-WorkloadSequenceFile -TempPath $tmp -FinalPath $finalPath
        if (-not $publish.Published) {
            if ($publish.Reason -eq 'exists') {
                return (New-WorkloadRefusal -Code 'workload_name_exists' -Key 'runner.workload_name_exists' -Arguments @{ tool = $tool; name = $Name; path = $finalPath })
            }
            return (New-WorkloadRefusal -Code 'workload_publish_failed' -Key 'runner.workload_publish_failed' -Arguments @{ tool = $tool; path = $finalPath; message = [string]$publish.Detail })
        }
        $published = $true
    } finally {
        if (-not $published -and (Test-Path -LiteralPath $tmp)) {
            try {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop
            } catch {
                Write-Verbose "The temporary candidate '$tmp' stays until the next save: $($_.Exception.Message)"
            }
        }
    }

    $relative = [IO.Path]::GetRelativePath([string]$Session.RepoRoot, $finalPath).Replace('\', '/')
    return [ordered]@{
        ok             = $true
        name           = $Name
        path           = $relative
        absolutePath   = $finalPath
        sequenceGuid   = $sequenceGuid
        steps          = $steps.Count
        componentSteps = $componentSteps.Count
        workloadSteps  = $workloadSteps.Count
        excluded       = [object[]]$excluded.ToArray()
    }
}

Export-ModuleMember -Function ConvertTo-WorkloadYamlScalar, ConvertTo-WorkloadStepText, ConvertTo-WorkloadSequenceText, `
    Resolve-WorkloadSequenceDestination, Publish-WorkloadSequenceFile, Save-WorkloadSequenceFile
