<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42a8e238-9fc4-4ca2-bdd0-9b55ac2ff25d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization boundary slice gate evidence
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
    Generate the Wave-1 affected-slice boundary map.
.DESCRIPTION
    Reverse-discovers stable-code producers and consumers from the code
    registry, adds the explicitly censused source signatures that have no code
    registry entry, and requires every discovered boundary to belong to one
    owned finding and at least one seeded slice.

    The authority manifest records expected consumers rather than waiving
    them. A new registry edge is unmapped, a removed edge/signature is stale,
    and either condition fails before a seed can be reported ready. Display-
    only census rows are kept in the same evidence but must name their Wave-2
    owner; they never block SEED-OPEN.
.PARAMETER Root
    Framework repository root. Defaults to this tool's repository.
.PARAMETER Manifest
    Authoritative finding, consumer, owner, and slice declarations.
.PARAMETER CodeRegistry
    Stable-code registry used for reverse discovery.
.PARAMETER OutputPath
    Generated evidence path.
.PARAMETER Update
    Write the deterministic generated evidence.
.PARAMETER Check
    Fail unless generated evidence is byte-for-byte current.
.PARAMETER Quiet
    Print only findings.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Root,
    [string]$Manifest,
    [string]$CodeRegistry,
    [string]$OutputPath,
    [switch]$Update,
    [switch]$Check,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if ($Update -and $Check) { throw '-Update and -Check are mutually exclusive.' }
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not $Manifest) { $Manifest = Join-Path $Root 'globalization/manifests/affected-slice-authority.json' }
if (-not $CodeRegistry) { $CodeRegistry = Join-Path $Root 'globalization/manifests/code-registry.json' }
if (-not $OutputPath) { $OutputPath = Join-Path $Root 'globalization/generated/affected-slice-map.json' }

$findings = [Collections.Generic.List[string]]::new()

function Add-Finding {
    param([Parameter(Mandatory)][string]$Text)
    $findings.Add($Text)
}

function Get-RelativeSourcePath {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) { return '' }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Path))
    if (-not $full.StartsWith($rootFull, [StringComparison]::Ordinal)) { return '' }
    return $Path.Replace('\', '/')
}

function ConvertTo-CommentStrippedSource {
    <#
    .SYNOPSIS
        Blank JavaScript and Go comments without disturbing quoted literals.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $chars = $Text.ToCharArray()
    $quote = [char]0
    $escaped = $false
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $current = $chars[$i]
        if ($quote -ne [char]0) {
            if ($escaped) { $escaped = $false; continue }
            if ($current -eq [char]0x5c -and $quote -ne [char]0x60) {
                $escaped = $true
                continue
            }
            if ($current -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($current -in @([char]0x27, [char]0x22, [char]0x60)) {
            $quote = $current
            continue
        }
        if ($current -ne [char]0x2f -or $i + 1 -ge $chars.Length) { continue }
        $next = $chars[$i + 1]
        if ($next -eq [char]0x2f) {
            while ($i -lt $chars.Length -and $chars[$i] -notin @([char]0x0a, [char]0x0d)) {
                $chars[$i] = [char]0x20
                $i++
            }
            $i--
        } elseif ($next -eq [char]0x2a) {
            $chars[$i] = [char]0x20
            $i++
            $chars[$i] = [char]0x20
            while ($i + 1 -lt $chars.Length) {
                if ($chars[$i] -eq [char]0x2a -and $chars[$i + 1] -eq [char]0x2f) {
                    $chars[$i] = [char]0x20
                    $chars[$i + 1] = [char]0x20
                    $i++
                    break
                }
                if ($chars[$i] -notin @([char]0x0a, [char]0x0d)) { $chars[$i] = [char]0x20 }
                $i++
            }
        }
    }
    return -join $chars
}

function Get-LiteralScanText {
    <#
    .SYNOPSIS
        Return source with real comments blanked for exact-literal discovery.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText($Path)
    $extension = [IO.Path]::GetExtension($Path)
    # Generated catalog tables define message keys; they do not consume wire
    # codes. Keep the surrounding application in the reverse-discovery scan.
    if ($extension -eq '.js') {
        $text = [regex]::Replace($text, '(?ms)^// >>> yuruna-i18n embedded block[^\r\n]*\r?\n.*?^// <<< yuruna-i18n embedded block[^\r\n]*(?:\r?\n|$)', '')
    }
    if ($extension -in @('.ps1', '.psm1')) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $chars = $text.ToCharArray()
        foreach ($token in @($tokens | Where-Object Kind -EQ 'Comment')) {
            for ($i = $token.Extent.StartOffset; $i -lt $token.Extent.EndOffset; $i++) {
                if ($chars[$i] -notin @([char]0x0a, [char]0x0d)) { $chars[$i] = [char]0x20 }
            }
        }
        return -join $chars
    }
    return ConvertTo-CommentStrippedSource -Text $text
}

function Get-ExactLiteralCount {
    <#
    .SYNOPSIS
        Count exact quoted code literals, not prose substrings or comments.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string[]]$Value
    )

    $count = 0
    foreach ($literal in @($Value | Where-Object { $_ } | Sort-Object -Unique)) {
        foreach ($quote in @([char]0x27, [char]0x22, [char]0x60)) {
            $needle = "$quote$literal$quote"
            $offset = 0
            while ($offset -lt $Text.Length) {
                $match = $Text.IndexOf($needle, $offset, [StringComparison]::Ordinal)
                if ($match -lt 0) { break }
                $count++
                $offset = $match + $needle.Length
            }
        }
    }
    return $count
}

function Get-ScannableSourcePath {
    <#
    .SYNOPSIS
        Enumerate bounded production source while excluding generated/test data.
    #>
    [OutputType([string[]])]
    param()

    $generatedDestinations = @{
        'test/status/qps-Ploc.status.js' = $true
        'test/status/qps-Plocm.status.js' = $true
        'test/extension/pool-control-service/server/internal/httpsrv/web/assets/qps-Ploc.pool.js' = $true
        'test/extension/pool-control-service/server/internal/httpsrv/web/assets/qps-Plocm.pool.js' = $true
    }
    $candidates = @()
    if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
        $gitFiles = @(& git -C $Root ls-files --cached --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -eq 0) { $candidates = @($gitFiles | ForEach-Object { [string]$_ }) }
    }
    if ($candidates.Count -eq 0) {
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push([IO.Path]::GetFullPath($Root))
        $fallback = [Collections.Generic.List[string]]::new()
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                if ([IO.Path]::GetFileName($child) -in @('.git', '.agents', '.codex', 'node_modules')) { continue }
                $pending.Push($child)
            }
            foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
                $fallback.Add([IO.Path]::GetRelativePath($Root, $file).Replace('\', '/'))
            }
        }
        $candidates = $fallback.ToArray()
    }
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($relative in $candidates) {
        # Shell is in scope because guest provisioning is written in it, and a
        # boundary is a boundary whichever language emits it: the retry wrapper
        # writes the record a diagnostic reads, and a scan that stopped at the
        # managed languages could not see the producing half of that pair at all.
        # Provisioning seeds are in scope for the same reason shell is: a seed
        # writes the exporter whose readings a diagnostic classifies, so the
        # producing half of that pair lives in a .user-data file and nowhere
        # else. A scan that stopped at the languages a compiler accepts would
        # report the consumer as unmapped and the producer as nonexistent.
        if ([IO.Path]::GetExtension($relative) -notin @('.ps1', '.psm1', '.go', '.js', '.sh', '.user-data')) { continue }
        if ($relative.StartsWith('globalization/generated/', [StringComparison]::Ordinal)) { continue }
        if ($relative.StartsWith('project/', [StringComparison]::Ordinal)) { continue }
        if ($relative.StartsWith('test/status/runtime/', [StringComparison]::Ordinal)) { continue }
        if ($generatedDestinations.ContainsKey($relative)) { continue }
        if ($relative -match '^test/extension/(?:extension-sdk|pool-control-service/server|stash-service/server|download-agent-service/server|caching-proxy-service|caching-proxy-parser-service|pool-aggregator-service)/internal/catalog/(?:registry|[A-Za-z0-9]+_[A-Za-z0-9]+)\.go$' -or
            $relative -match '^test/(?:status/|extension/(?:pool-control-service|stash-service|download-agent-service)/server/internal/httpsrv/web/assets/)[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\.[a-z]+\.js$') {
            $generatedText = [IO.File]::ReadAllText((Join-Path $Root $relative))
            if ($generatedText.StartsWith('// Generated by tools/Invoke-CatalogCompile.ps1', [StringComparison]::Ordinal) -or
                $generatedText.StartsWith('// Generated by tools/Invoke-CatalogEmbed.ps1', [StringComparison]::Ordinal)) { continue }
        }
        if ($relative -match '(?i)(?:\.Tests\.ps1|_test\.go|\.test\.js)$') { continue }
        $paths.Add($relative)
    }
    return @($paths | Sort-Object -Unique)
}

foreach ($required in @($Manifest, $CodeRegistry)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Output "Invoke-AffectedSliceMap: required manifest is missing: $required"
        exit 2
    }
}

try { $authority = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Manifest)) }
catch { Write-Output "Invoke-AffectedSliceMap: authority is not valid JSON: $($_.Exception.Message)"; exit 2 }
try { $registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($CodeRegistry)) }
catch { Write-Output "Invoke-AffectedSliceMap: code registry is not valid JSON: $($_.Exception.Message)"; exit 2 }

if ($authority.schema -cne 'yuruna.affected-slice-authority/v1') {
    Add-Finding "unsupported authority schema '$($authority.schema)'"
}
if ($registry.schema -cne 'yuruna.code-registry/v1') {
    Add-Finding "unsupported code-registry schema '$($registry.schema)'"
}

$sourceTextByPath = @{}
foreach ($sourcePath in @(Get-ScannableSourcePath)) {
    try {
        $sourceTextByPath[$sourcePath] = Get-LiteralScanText -Path (Join-Path $Root $sourcePath)
    } catch {
        Add-Finding "source literal scan could not read '$sourcePath': $($_.Exception.Message)"
    }
}

# Generic values such as "denied" legitimately occur in other protocols. Each
# unrelated exact literal is reviewed by path and composite code identity; a
# path-wide or token-wide suppression would hide the next real consumer.
$literalExclusionByKey = @{}
foreach ($exclusion in @($authority.literalExclusions | Where-Object { $null -ne $_ })) {
    $wireCode = [string]$exclusion.wireCode
    $path = Get-RelativeSourcePath -Path ([string]$exclusion.path)
    $key = "$wireCode`n$path"
    if ([string]::IsNullOrWhiteSpace($wireCode) -or -not $path) {
        Add-Finding "source literal exclusion has an invalid code/path ('$wireCode', '$($exclusion.path)')"
        continue
    }
    if ($literalExclusionByKey.ContainsKey($key)) {
        Add-Finding "duplicate source literal exclusion for '$wireCode' in '$path'"
        continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$exclusion.reason)) {
        Add-Finding "source literal exclusion for '$wireCode' in '$path' has no reason"
    }
    if ($null -eq $exclusion.matchCount -or [int]$exclusion.matchCount -lt 1) {
        Add-Finding "source literal exclusion for '$wireCode' in '$path' has no positive matchCount"
    }
    $literalExclusionByKey[$key] = $exclusion
}

$sliceById = @{}
foreach ($slice in @($authority.seededSlices)) {
    $id = [string]$slice.id
    if ([string]::IsNullOrWhiteSpace($id)) { Add-Finding 'seeded slice has no id'; continue }
    if ($sliceById.ContainsKey($id)) { Add-Finding "duplicate seeded slice '$id'"; continue }
    if ([string]$slice.nextOwner -notmatch '^G2-\d{2}$') { Add-Finding "seeded slice '$id' has no named G2 owner" }
    if (@($slice.domains).Count -eq 0) { Add-Finding "seeded slice '$id' has no reachable domain" }
    $sliceById[$id] = $slice
}

# Registry entries are the discoverable authority for stable-code boundaries.
# The edge id includes the code, role, and file so adding or removing any one
# edge changes the discovered set even when the same file carries another code.
$consumerById = @{}
$knownWireCodes = @{}
$usedLiteralExclusions = @{}
foreach ($entry in @($registry.codes | Sort-Object { [string]$_.wireCode })) {
    $wireCode = [string]$entry.wireCode
    if ([string]::IsNullOrWhiteSpace($wireCode)) { Add-Finding 'code-registry row has no wireCode'; continue }
    if ($knownWireCodes.ContainsKey($wireCode)) {
        Add-Finding "duplicate code-registry wireCode '$wireCode'"
        continue
    }
    $knownWireCodes[$wireCode] = $true
    $runtimeCode = [string]$entry.code
    if ([string]::IsNullOrWhiteSpace($runtimeCode)) {
        Add-Finding "code-registry row '$wireCode' has no runtime code"
        continue
    }
    $literalValues = @(@($runtimeCode, $wireCode) | Sort-Object -Unique)
    $declaredPaths = @{}
    foreach ($role in @('producer', 'consumer')) {
        $property = if ($role -eq 'producer') { 'producedBy' } else { 'consumedBy' }
        foreach ($declaredPath in @($entry.$property | ForEach-Object { [string]$_ } | Sort-Object -Unique)) {
            $path = Get-RelativeSourcePath -Path $declaredPath
            if (-not $path) { Add-Finding "code '$wireCode' has invalid $role path '$declaredPath'"; continue }
            $id = "code:$wireCode`:$role`:$path"
            if ($consumerById.ContainsKey($id)) { Add-Finding "duplicate discovered boundary consumer '$id'"; continue }
            $full = Join-Path $Root $path
            $count = 0
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                Add-Finding "known boundary consumer was deleted: $id"
            } else {
                try {
                    $scanText = if ($sourceTextByPath.ContainsKey($path)) {
                        [string]$sourceTextByPath[$path]
                    } else {
                        Get-LiteralScanText -Path $full
                    }
                    $count = Get-ExactLiteralCount -Text $scanText -Value $literalValues
                    if ($count -eq 0) {
                        Add-Finding "declared boundary consumer carries neither '$runtimeCode' nor '$wireCode': $id"
                    }
                } catch {
                    Add-Finding "declared boundary consumer could not be scanned: $id ($($_.Exception.Message))"
                }
            }
            $consumerById[$id] = [ordered]@{
                id = $id; source = 'code-registry'; path = $path
                code = $wireCode; role = $role; matchCount = $count
            }
            $declaredPaths[$path] = $true
        }
    }

    # Reverse discovery is deliberately independent from producedBy/consumedBy.
    # A newly added exact literal becomes a source edge and therefore must be
    # mapped, declared, or narrowly classified as an unrelated same-word use.
    foreach ($path in @($sourceTextByPath.Keys | Sort-Object)) {
        $count = Get-ExactLiteralCount -Text ([string]$sourceTextByPath[$path]) -Value $literalValues
        if ($count -eq 0 -or $declaredPaths.ContainsKey($path)) { continue }
        $exclusionKey = "$wireCode`n$path"
        if ($literalExclusionByKey.ContainsKey($exclusionKey)) {
            $exclusion = $literalExclusionByKey[$exclusionKey]
            $usedLiteralExclusions[$exclusionKey] = $true
            if ([int]$exclusion.matchCount -ne $count) {
                Add-Finding "source literal exclusion for '$wireCode' in '$path' expected $($exclusion.matchCount), found $count"
            }
            continue
        }
        $id = "code:$wireCode`:source:$path"
        Add-Finding "unclassified source-only code literal '$wireCode' in '$path'; declare its role or add an exact reviewed exclusion"
        $consumerById[$id] = [ordered]@{
            id = $id; source = 'source-literal'; path = $path
            code = $wireCode; role = 'source'; matchCount = $count
        }
    }
}

foreach ($key in @($literalExclusionByKey.Keys | Sort-Object)) {
    $exclusion = $literalExclusionByKey[$key]
    $wireCode = [string]$exclusion.wireCode
    $path = Get-RelativeSourcePath -Path ([string]$exclusion.path)
    if (-not $knownWireCodes.ContainsKey($wireCode)) {
        Add-Finding "source literal exclusion names unknown wireCode '$wireCode' ($path)"
    } elseif (-not $usedLiteralExclusions.ContainsKey($key)) {
        Add-Finding "stale source literal exclusion for '$wireCode' in '$path'"
    }
}

# Some bounded Wave-1 findings predate the stable-code registry or are source
# invariants rather than enumerations. Their exact signatures are still
# discovered from code, never inferred from plan prose.
$signatureIds = @{}
foreach ($signature in @($authority.signatureConsumers | Sort-Object { [string]$_.id })) {
    $id = [string]$signature.id
    if ([string]::IsNullOrWhiteSpace($id)) { Add-Finding 'signature consumer has no id'; continue }
    if ($signatureIds.ContainsKey($id) -or $consumerById.ContainsKey($id)) {
        Add-Finding "duplicate signature consumer '$id'"; continue
    }
    $signatureIds[$id] = $true
    $path = Get-RelativeSourcePath -Path ([string]$signature.path)
    if (-not $path) { Add-Finding "signature '$id' has invalid path '$($signature.path)'"; continue }
    $full = Join-Path $Root $path
    $count = 0
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Add-Finding "known boundary consumer was deleted: $id ($path)"
    } else {
        $minimum = if ($null -ne $signature.minimumMatches) { [int]$signature.minimumMatches } else { 1 }
        if ($minimum -lt 1) {
            Add-Finding "signature '$id' minimumMatches must be at least 1"
            # Keep evaluating against the fail-closed default so malformed
            # authority cannot turn a deleted implementation into zero-of-zero.
            $minimum = 1
        }
        try {
            $pattern = [regex]::new([string]$signature.pattern,
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)
            $count = $pattern.Matches((Get-LiteralScanText -Path $full)).Count
        } catch {
            Add-Finding "signature '$id' has invalid regex: $($_.Exception.Message)"
        }
        if ($count -lt $minimum) {
            Add-Finding "known boundary consumer was deleted or renamed: $id ($path; found $count, need $minimum)"
        }
        if ($null -ne $signature.maximumMatches -and $count -gt [int]$signature.maximumMatches) {
            Add-Finding "signature '$id' discovered $count consumers, above maximum $($signature.maximumMatches)"
        }
    }
    $consumerById[$id] = [ordered]@{
        id = $id; source = 'source-signature'; path = $path
        code = ''; role = 'consumer'; matchCount = $count
    }
}

$rowById = @{}
$mappedByConsumer = @{}
foreach ($row in @($authority.rows)) {
    $id = [string]$row.id
    if ([string]::IsNullOrWhiteSpace($id)) { Add-Finding 'authority contains an unknown row with no id'; continue }
    if ($rowById.ContainsKey($id)) { Add-Finding "duplicate authority row '$id'"; continue }
    $rowById[$id] = $row

    $kind = [string]$row.kind
    if ($kind -notin @('blocker', 'display-only-census', 'catalog-boundary')) {
        Add-Finding "unknown row kind '$kind' on '$id'"
    }
    $status = [string]$row.status
    if ($kind -eq 'blocker' -and $status -notin @('open', 'closed')) {
        Add-Finding "blocker row '$id' has unknown status '$status'"
    }
    if ($kind -eq 'display-only-census' -and $status -cne 'deferred') {
        Add-Finding "display-only row '$id' must have deferred status"
    }
    if ($kind -eq 'catalog-boundary' -and $status -cne 'implemented') {
        Add-Finding "catalog boundary '$id' must identify an implemented typed boundary"
    }
    $owner = [string]$row.owner
    if ([string]::IsNullOrWhiteSpace($owner)) {
        Add-Finding "unowned row '$id'"
    } elseif ($kind -eq 'blocker' -and $owner -cne 'G1-08') {
        Add-Finding "C blocker '$id' is owned by '$owner', not G1-08"
    } elseif ($kind -eq 'display-only-census' -and $owner -notmatch '^G2-\d{2}$') {
        Add-Finding "display-only row '$id' has no named G2 owner"
    } elseif ($kind -eq 'catalog-boundary' -and $owner -notmatch '^G2-\d{2}$') {
        Add-Finding "catalog boundary '$id' has no named G2 owner"
    }
    if ($kind -eq 'catalog-boundary') {
        $verification = Get-RelativeSourcePath -Path ([string]$row.verification)
        if (-not $verification -or -not (Test-Path -LiteralPath (Join-Path $Root $verification) -PathType Leaf)) {
            Add-Finding "catalog boundary '$id' has no existing verification suite"
        }
    }

    $rowSlices = @($row.slices | ForEach-Object { [string]$_ })
    $rowDomains = @($row.domains | ForEach-Object { [string]$_ })
    if ($kind -eq 'blocker' -and $rowSlices.Count -eq 0) {
        Add-Finding "C blocker row '$id' has no affected slice"
    } elseif ($rowSlices.Count -eq 0 -and $rowDomains.Count -eq 0) {
        Add-Finding "row '$id' names neither an affected slice nor a domain"
    }
    foreach ($sliceId in $rowSlices) {
        if (-not $sliceById.ContainsKey($sliceId)) { Add-Finding "row '$id' names unknown slice '$sliceId'" }
    }
    $rowConsumers = @($row.consumers | ForEach-Object { [string]$_ })
    if ($rowConsumers.Count -eq 0) { Add-Finding "row '$id' has no boundary consumer" }
    foreach ($consumerId in $rowConsumers) {
        if (-not $consumerById.ContainsKey($consumerId)) {
            Add-Finding "known boundary consumer was deleted or renamed: $consumerId (row $id)"
            continue
        }
        if ($mappedByConsumer.ContainsKey($consumerId)) {
            Add-Finding "boundary consumer '$consumerId' is mapped by both '$($mappedByConsumer[$consumerId])' and '$id'"
        } else { $mappedByConsumer[$consumerId] = $id }
    }
}

foreach ($consumerId in @($consumerById.Keys | Sort-Object)) {
    if (-not $mappedByConsumer.ContainsKey($consumerId)) {
        Add-Finding "unknown/unmapped boundary consumer '$consumerId'"
    }
}

if ($findings.Count -gt 0) {
    foreach ($finding in @($findings | Sort-Object -Unique)) { Write-Output "FINDING: $finding" }
    Write-Output "Invoke-AffectedSliceMap: $($findings.Count) finding(s)."
    exit 1
}

$generatedRows = @($rowById.Keys | Sort-Object | ForEach-Object {
    $row = $rowById[$_]
    $rowSlices = @($row.slices | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $rowDomains = @(
        @($row.domains | ForEach-Object { [string]$_ }) +
        @($rowSlices | ForEach-Object { $sliceById[$_].domains } | ForEach-Object { [string]$_ }) |
            Where-Object { $_ } | Sort-Object -Unique
    )
    [ordered]@{
        id = [string]$row.id
        kind = [string]$row.kind
        status = [string]$row.status
        owner = [string]$row.owner
        verification = [string]$row.verification
        slices = $rowSlices
        domains = $rowDomains
        consumers = @($row.consumers | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }
})
$generatedConsumers = @($consumerById.Keys | Sort-Object | ForEach-Object {
    $consumer = $consumerById[$_]
    [ordered]@{
        id = [string]$consumer.id
        finding = [string]$mappedByConsumer[$_]
        source = [string]$consumer.source
        path = [string]$consumer.path
        code = [string]$consumer.code
        role = [string]$consumer.role
        matchCount = [int]$consumer.matchCount
    }
})
$generatedLiteralExclusions = @($literalExclusionByKey.Keys | Sort-Object | ForEach-Object {
    $exclusion = $literalExclusionByKey[$_]
    [ordered]@{
        wireCode = [string]$exclusion.wireCode
        path = (Get-RelativeSourcePath -Path ([string]$exclusion.path))
        matchCount = [int]$exclusion.matchCount
        reason = [string]$exclusion.reason
    }
})
$generatedSlices = @($sliceById.Keys | Sort-Object | ForEach-Object {
    $sliceId = $_
    $slice = $sliceById[$sliceId]
    $reachable = @($generatedRows | Where-Object {
            $_.kind -eq 'blocker' -and @($_.slices) -ccontains $sliceId
        } | ForEach-Object { [string]$_.id } | Sort-Object)
    $open = @($generatedRows | Where-Object {
            $_.kind -eq 'blocker' -and $_.status -eq 'open' -and @($_.slices) -ccontains $sliceId
        } | ForEach-Object { [string]$_.id } | Sort-Object)
    [ordered]@{
        id = $sliceId
        domains = @($slice.domains | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        nextOwner = [string]$slice.nextOwner
        reachableBlockers = $reachable
        openBlockers = $open
        seedOpen = ($open.Count -eq 0)
    }
})

$document = [ordered]@{
    schema = 'yuruna.affected-slice-map/v1'
    authoritySchema = [string]$authority.schema
    codeRegistrySchema = [string]$registry.schema
    slices = $generatedSlices
    rows = $generatedRows
    consumers = $generatedConsumers
    literalExclusions = $generatedLiteralExclusions
    summary = [ordered]@{
        sliceCount = $generatedSlices.Count
        blockerCount = @($generatedRows | Where-Object kind -EQ 'blocker').Count
        openBlockerCount = @($generatedRows | Where-Object { $_.kind -eq 'blocker' -and $_.status -eq 'open' }).Count
        displayOnlyCount = @($generatedRows | Where-Object kind -EQ 'display-only-census').Count
        catalogBoundaryCount = @($generatedRows | Where-Object kind -EQ 'catalog-boundary').Count
        consumerCount = $generatedConsumers.Count
        literalExclusionCount = $generatedLiteralExclusions.Count
    }
}
$json = ($document | ConvertTo-Json -Depth 12) -replace "`r`n", "`n"
$json += "`n"

if ($Check) {
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        Write-Output "FINDING: generated affected-slice map is missing: $OutputPath"
        exit 1
    }
    $recorded = [IO.File]::ReadAllText($OutputPath) -replace "`r`n", "`n"
    if ($recorded -cne $json) {
        Write-Output 'FINDING: generated affected-slice map is stale; run tools/Invoke-AffectedSliceMap.ps1 -Update'
        exit 1
    }
} elseif ($Update) {
    $parent = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($parent, 'Create generated evidence directory')) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write affected-slice map')) {
        [IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
    }
} elseif (-not $Quiet) {
    Write-Output $json.TrimEnd()
}

if (-not $Quiet) {
    $ready = @($generatedSlices | Where-Object seedOpen).Count
    Write-Output "Invoke-AffectedSliceMap: $ready/$($generatedSlices.Count) seeded slice(s) have zero reachable open C blockers."
}
exit 0
