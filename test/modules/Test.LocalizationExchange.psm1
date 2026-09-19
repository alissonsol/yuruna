<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42b6c05e-7d19-4a83-95f2-c81d3e6470ab
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization localization exchange request attestation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    The rows a language is made of, and the digest that binds an answer to the
    request that asked for it.
.DESCRIPTION
    Everything a translator is asked about -- a term, a retired-name ruling, a
    style rule, a message, a document, an official project scalar -- is one row
    with one identity and one source digest. Both ends of the exchange read
    this module, so the folder that goes out and the folder that comes back
    cannot disagree about what a row is.

    A row's identity carries the repository it belongs to wherever two
    repositories can hold the same name. That is not defensive spelling: a
    README.md exists in both trees, and an identity that omitted the repository
    would let one answer be recorded against a file nobody read.
.NOTES
    Ordinal ordering and comparison throughout. The request digest is compared
    byte for byte between two machines, and a culture-aware collation would
    give the same rows two different digests without changing a word.
#>

Set-StrictMode -Version 3.0

# -Global because a nested import without it defines the dependency's commands
# only inside this module's own session state, and the caller that imported
# this one is then missing them.
Import-Module (Join-Path $PSScriptRoot 'Test.ApprovalDigest.psm1') -Force -Global -DisableNameChecking

$script:RequestDigestAlgorithm = 'sha256-canonical-request-v1'
$script:RequestSchema = 'yuruna.localization-request/v1'
$script:AttestationSchema = 'yuruna.localization-attestation/v1'

function Get-LocalizationExchangeSchema {
    <#
    .SYNOPSIS
        The schema tags and digest algorithm both ends write.
    .OUTPUTS
        [ordered]
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return [ordered]@{
        request = $script:RequestSchema
        attestation = $script:AttestationSchema
        digestAlgorithm = $script:RequestDigestAlgorithm
    }
}

function Get-TextSha256 {
    <#
    .SYNOPSIS
        The hex sha256 of a string's UTF-8 bytes, with no byte-order mark.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))
    } finally {
        $sha.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function New-LocalizationRow {
    <#
    .SYNOPSIS
        One question for the localization team, with everything needed to ask it.
    .OUTPUTS
        [ordered]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns a value; changes nothing.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('term', 'ruling', 'style-rule', 'message', 'document', 'project-scalar')]
        [string]$Kind,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][AllowEmptyString()][string]$English,
        [string]$Repo = '',
        [string]$Pointer = '',
        [AllowEmptyString()][string]$Context = ''
    )

    return [ordered]@{
        id = $Id
        kind = $Kind
        repo = $Repo
        file = $File
        pointer = $Pointer
        english = $English
        context = $Context
        sourceSha256 = Get-TextSha256 -Text $English
    }
}

function Get-TerminologyRow {
    <#
    .SYNOPSIS
        The glossary rows: source terms, retired-name rulings, and style rules.
    .DESCRIPTION
        A term's question is its source spelling plus what it means here, not
        the word alone. Two Yuruna concepts can share an English word, and a
        translator handed only the word would have to guess which one.
    .OUTPUTS
        [object[]]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Locale)

    $rows = [Collections.Generic.List[object]]::new()
    $termsPath = Join-Path $Root ('globalization/terminology/{0}.terms.json' -f $Locale)
    if ([IO.File]::Exists($termsPath)) {
        $terms = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($termsPath))
        foreach ($term in @($terms.terms)) {
            $source = [string]$term.sourceTerm
            $meaning = [string]$term.meaning
            $headings = @($term.PSObject.Properties.Name -contains 'sourceHeadings' ? $term.sourceHeadings : @())
            $rows.Add((New-LocalizationRow -Id ('term:{0}' -f $source) -Kind 'term' `
                        -File 'glossary/terms.json' -Pointer $source `
                        -English ("{0}`n{1}" -f $source, $meaning) `
                        -Context (@($headings | ForEach-Object { [string]$_ }) -join '; ')))
        }
        foreach ($ruling in @($terms.retiredNameRulings)) {
            # The retired spelling is the identity: it is the exact English a
            # machine still searches for, which is why the ruling exists.
            $names = @($ruling.PSObject.Properties.Name)
            $id = if ($names -contains 'retired') { [string]$ruling.retired } else { '' }
            if (-not $id) { throw 'a retired-name ruling names no retired spelling' }
            $text = ConvertTo-Json -InputObject $ruling -Depth 10 -Compress
            $rows.Add((New-LocalizationRow -Id ('ruling:{0}' -f $id) -Kind 'ruling' `
                        -File 'glossary/rulings.json' -Pointer $id -English $text))
        }
    }
    $stylePath = Join-Path $Root ('globalization/terminology/{0}.style-guide.json' -f $Locale)
    if ([IO.File]::Exists($stylePath)) {
        $style = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($stylePath))
        foreach ($rule in @($style.rules)) {
            # The topic is the question and the guidance is the answer. A style
            # rule is authored for the locale rather than translated from
            # English, so putting the guidance in the row's source would make
            # every rewrite of it reopen the row that produced the rewrite.
            $rows.Add((New-LocalizationRow -Id ('style-rule:{0}' -f [string]$rule.id) -Kind 'style-rule' `
                        -File 'glossary/style-guide.json' -Pointer ([string]$rule.id) `
                        -English ([string]$rule.topic) -Context ([string]$rule.guidance)))
        }
    }
    return $rows.ToArray()
}

function Get-MessageRow {
    <#
    .SYNOPSIS
        One row per message in every source catalog domain.
    .DESCRIPTION
        The question is the message plus its description, because the
        description is what tells a translator where the words appear and
        which of two readings is meant. A plural message asks about every
        variant at once: they are one decision in the target language, not two.
    .OUTPUTS
        [object[]]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Root, [string]$SourceLocale = 'en-US', [string]$Locale)

    $rows = [Collections.Generic.List[object]]::new()
    $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Root 'globalization/locale-manifest.json')))
    $directory = Join-Path $Root ('globalization/catalogs/{0}' -f $SourceLocale)
    if (-not [IO.Directory]::Exists($directory)) { return $rows.ToArray() }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' | Sort-Object -Property Name)) {
        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName))
        $domain = [string]$catalog.domain
        foreach ($code in (Get-OrdinalSortedName -Name @($catalog.messages.PSObject.Properties.Name | Where-Object { $_ }))) {
            $entry = $catalog.messages.$code
            $names = @($entry.PSObject.Properties.Name)
            if ($names -contains 'lifecycle' -and $entry.lifecycle -ceq 'tombstone') { continue }
            $kind = if ($names -contains 'plural') { 'plural' } elseif ($names -contains 'select') { 'select' } else { 'message' }
            $text = if ($kind -ceq 'message') { [string]$entry.message } else {
                $variants = [ordered]@{}
                foreach ($property in $entry.$kind.variants.PSObject.Properties) { $variants[$property.Name] = $property.Value }
                if ($kind -ceq 'plural' -and $Locale -and $manifest.locales.$Locale.PSObject.Properties['pluralCategories']) {
                    foreach ($category in @($manifest.locales.$Locale.pluralCategories)) {
                        if (-not $variants.Contains([string]$category)) { $variants[[string]$category] = [string]$entry.plural.variants.other }
                    }
                }
                ConvertTo-Json -InputObject $variants -Depth 20 -Compress
            }
            $description = if ($names -contains 'description') { [string]$entry.description } else { '' }
            $row = New-LocalizationRow -Id ('message:{0}:{1}' -f $domain, $code) -Kind 'message' `
                -File ('messages/{0}.json' -f $domain) -Pointer $code -English $text -Context $description
            $row.sourceSha256 = Get-LocalizationMessageHash -Key $code -Message $entry
            $rows.Add($row)
        }
    }
    return $rows.ToArray()
}

function Get-DocumentRow {
    <#
    .SYNOPSIS
        One row per mapped document, identified by repository and source path.
    .DESCRIPTION
        The repository is part of the identity because both trees carry a
        README.md. They are different documents that a reviewer reads
        separately, and one answer covering both would record a review of one
        as a review of the other.
    .OUTPUTS
        [object[]]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Locale
    )

    $rows = [Collections.Generic.List[object]]::new()
    $manifestPath = Join-Path $Root 'globalization/manifests/doc-translations.json'
    if (-not [IO.File]::Exists($manifestPath)) { return $rows.ToArray() }
    $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath))
    foreach ($document in @($manifest.documents)) {
        if ([string]$document.locale -cne $Locale) { continue }
        $repo = [string]$document.repo
        $source = [string]$document.source
        $tree = if ($repo -ceq 'yuruna') { $Root } else { $ProjectRoot }
        $full = Join-Path $tree $source
        if (-not [IO.File]::Exists($full)) { continue }
        $text = [IO.File]::ReadAllText($full).Replace("`r`n", "`n")
        $rows.Add((New-LocalizationRow -Id ('document:{0}:{1}' -f $repo, $source) -Kind 'document' `
                    -Repo $repo -File ('documents/{0}/{1}' -f $repo, $source) -Pointer $source `
                    -English $text -Context ([string]$document.translated)))
    }
    return $rows.ToArray()
}

function Get-ProjectScalarRow {
    <#
    .SYNOPSIS
        One row per official project display scalar.
    .DESCRIPTION
        The sidecar names every enrolled field. Its current English and source
        hash are read from real YAML, so stale sidecar hashes cannot disguise a
        changed scalar and an unavailable codec stops the handoff.
    .OUTPUTS
        [object[]]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Locale)

    $rows = [Collections.Generic.List[object]]::new()
    $record = Get-LocalizationProjectSource -ProjectRoot $ProjectRoot -Locale $Locale
    Assert-LocalizationYamlCodec
    $cache = @{}
    foreach ($entry in @($record.entries)) {
        if ([string]$entry.locale -cne $Locale) { continue }
        $path = [string]$entry.path
        $pointer = [string]$entry.fieldPath
        if (-not $cache.ContainsKey($path)) {
            $full = Resolve-LocalizationPath -Root $ProjectRoot -Relative $path
            if (-not [IO.File]::Exists($full)) { throw "Missing project scalar source: $path" }
            $cache[$path] = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($full)) -Ordered
        }
        $english = Get-YamlPointerValue -Document $cache[$path] -Pointer $pointer
        if (-not $english) { throw "Missing project display scalar: $path#$pointer" }
        $row = New-LocalizationRow -Id ('project-scalar:{0}:{1}' -f $path, $pointer) -Kind 'project-scalar' `
            -Repo 'yuruna-project' -File 'project/display-map.json' -Pointer $pointer -English $english -Context $path
        $row.sourceSha256 = Get-TextSha256 -Text $english.Normalize([Text.NormalizationForm]::FormC)
        $rows.Add($row)
    }
    return $rows.ToArray()
}

function Get-LocalizationProjectSource {
    <#
    .SYNOPSIS
        Enroll official test-set, sequence, and visible-step display metadata.
    .DESCRIPTION
        English displayName/description scalars are discovered from runner and
        sequence YAML. Command, pattern, application, book, and nested-host
        fixture trees are excluded. Existing sidecar rows retain enrollment for
        explicitly registered external layouts.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$ProjectRoot, [string]$Locale)
    Assert-LocalizationYamlCodec
    $entries = @{}
    $sidecar = Join-Path $ProjectRoot 'globalization/project-locale-source-hashes.json'
    if ([IO.File]::Exists($sidecar)) {
        $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($sidecar)) -AsHashtable
        foreach ($entry in $record.entries) { if ($entry.locale -ceq $Locale) { $entries[$entry.path + '|' + $entry.fieldPath] = $entry } }
    }
    function Add-ProjectDisplayScalar {
        param($Node, [string]$Pointer, [string]$Relative)
        if ($Node -is [Collections.IDictionary]) {
            foreach ($field in @('displayName', 'description')) {
                if ($Node.Contains($field) -and $Node[$field] -is [string] -and $Node[$field].Trim()) {
                    $fieldPath = $Pointer + '/' + $field
                    $identity = $Relative + '|' + $fieldPath
                    if (-not $entries.ContainsKey($identity)) {
                        $entries[$identity] = @{ path = $Relative; fieldPath = $fieldPath; locale = $Locale; sourceHash = Get-TextSha256 -Text $Node[$field].Normalize([Text.NormalizationForm]::FormC); reviewStatus = 'unreviewed' }
                    }
                }
            }
            foreach ($key in $Node.Keys) {
                if ([string]$key -match 'Localized$' -or [string]$key -in @('variables', 'globalVariables')) { continue }
                $segment = ([string]$key).Replace('~', '~0').Replace('/', '~1')
                Add-ProjectDisplayScalar -Node $Node[$key] -Pointer ($Pointer + '/' + $segment) -Relative $Relative
            }
        } elseif ($Node -is [Collections.IList]) {
            for ($index = 0; $index -lt $Node.Count; $index++) {
                $item = $Node[$index]
                $segment = [string]$index
                if ($item -is [Collections.IDictionary] -and $item.Contains('name') -and $item['name']) { $segment = 'name=' + ([string]$item['name']).Replace('~', '~0').Replace('/', '~1') }
                Add-ProjectDisplayScalar -Node $item -Pointer ($Pointer + '/' + $segment) -Relative $Relative
            }
        }
    }
    foreach ($directory in @('test', 'template', 'example')) {
        $base = Join-Path $ProjectRoot $directory
        if (-not [IO.Directory]::Exists($base)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $base -Recurse -File | Where-Object Extension -In @('.yml', '.yaml') | Sort-Object FullName)) {
            $relative = [IO.Path]::GetRelativePath($ProjectRoot, $file.FullName).Replace('\', '/')
            if ($relative -notmatch '^(test/|template/(?:.*/)?test/|example/(?!nested\.host/).*/test/)' -or $relative -match '/(?:components|workloads)/') { continue }
            $null = Resolve-LocalizationPath -Root $ProjectRoot -Relative $relative
            $document = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($file.FullName)) -Ordered
            if ($document -isnot [Collections.IDictionary]) { continue }
            $orchestration = $document.Contains('name') -and $document.Contains('steps') -and ([IO.File]::ReadAllText($file.FullName) -match '(?m)^#\s*yaml-language-server:\s*\$schema=.*[/\\]orchestration-sequence\.schema\.yml\s*$')
            if (-not $document.Contains('sequenceGuid') -and -not $document.Contains('testSets') -and -not $orchestration) { continue }
            Add-ProjectDisplayScalar -Node $document -Pointer '' -Relative $relative
        }
    }
    return @{ schema = 'yuruna.project-locale-source-hashes/v1'; hashAlgorithm = 'sha256-utf8-nfc-scalar-v1'; entries = @($entries.Values | Sort-Object path, fieldPath) }
}

function Get-YamlPointerValue {
    <#
    .SYNOPSIS
        The scalar a project field pointer names, or an empty string.
    .DESCRIPTION
        Pointer segments are either a mapping key or a `name=value` selector
        that picks one element out of a sequence, which is how the project maps
        address a named test set without depending on its position.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Document, [Parameter(Mandatory)][string]$Pointer)

    if ($null -eq $Document) { return '' }
    $node = $Document
    foreach ($encoded in @($Pointer.Split('/') | Where-Object { $_ })) {
        $segment = $encoded.Replace('~1', '/').Replace('~0', '~')
        if ($null -eq $node) { return '' }
        if ($segment -match '^(?<key>[^=]+)=(?<value>.+)$') {
            $key = $Matches['key']
            $wanted = $Matches['value']
            $found = $null
            foreach ($item in @($node)) {
                if ($item -is [Collections.IDictionary] -and $item.Contains($key) -and
                    [string]::Equals([string]$item[$key], $wanted, [StringComparison]::Ordinal)) {
                    $found = $item
                    break
                }
            }
            $node = $found
            continue
        }
        if ($node -is [Collections.IList] -and $segment -match '^\d+$') { $node = $node[[int]$segment]; continue }
        # Assign inside the branch. Returning a one-element YAML sequence from
        # an if-expression enumerates it into its sole mapping, which loses
        # the numeric pointer segment before the next traversal step.
        if ($node -is [Collections.IDictionary] -and $node.Contains($segment)) { $node = $node[$segment] }
        else { $node = $null }
    }
    if ($null -eq $node -or $node -is [Collections.IDictionary] -or $node -is [array]) { return '' }
    return [string]$node
}

function Get-LocalizationRow {
    <#
    .SYNOPSIS
        Every row a locale is made of, in ordinal identity order.
    .OUTPUTS
        [object[]]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Locale,
        [string]$SourceLocale = 'en-US'
    )

    $rows = [Collections.Generic.List[object]]::new()
    $rows.AddRange([object[]](Get-TerminologyRow -Root $Root -Locale $Locale))
    $rows.AddRange([object[]](Get-MessageRow -Root $Root -SourceLocale $SourceLocale -Locale $Locale))
    $rows.AddRange([object[]](Get-DocumentRow -Root $Root -ProjectRoot $ProjectRoot -Locale $Locale))
    $rows.AddRange([object[]](Get-ProjectScalarRow -ProjectRoot $ProjectRoot -Locale $Locale))

    $byId = @{}
    foreach ($row in $rows) {
        if ($byId.ContainsKey([string]$row.id)) { throw "Duplicate localization row: $($row.id)" }
        $byId[[string]$row.id] = $row
    }
    $ordered = foreach ($id in (Get-OrdinalSortedName -Name @($byId.Keys | Where-Object { $_ }))) { $byId[$id] }
    # Emitted rather than wrapped: every caller re-collects this with @(), and a
    # wrapper would arrive there as one nested array instead of the rows.
    return @($ordered)
}

function Get-LocalizationRequestDigest {
    <#
    .SYNOPSIS
        The digest an answer has to repeat to be an answer to this request.
    .DESCRIPTION
        It covers each row's identity, kind and source digest, and nothing
        else. The generation time, the operator, and every translation are
        outside it, so re-exporting an unchanged tree asks the same question
        and a returned bundle can be checked against the request it claims to
        answer.
    .OUTPUTS
        [ordered] algorithm, sha256
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row, [ValidateSet('Json', 'Csv', 'Xliff')][string]$Format = 'Json')

    # Not `$row`: PowerShell variable names are case-insensitive, so a loop
    # variable spelled like its parameter destroys the collection it walks.
    $projection = foreach ($item in $Row) {
        [ordered]@{ id = [string]$item.id; kind = [string]$item.kind; sourceSha256 = [string]$item.sourceSha256; english = [string]$item.english }
    }
    $canonical = ConvertTo-CanonicalApprovalJson -Value ([ordered]@{ format = $Format; rows = @($projection) })
    return [ordered]@{ algorithm = $script:RequestDigestAlgorithm; sha256 = Get-TextSha256 -Text $canonical }
}

function Test-LocalizationAttestation {
    <#
    .SYNOPSIS
        Whether a returned attestation can be recorded as an approval.
    .DESCRIPTION
        Four things have to hold, and each of them has been wrong before in a
        way that still produced a file that looked complete: the bundle answers
        the request it claims to, two different people signed it, neither date
        is in the future, and both roles are present.
    .OUTPUTS
        [pscustomobject] Ok, Detail
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Attestation,
        [Parameter(Mandatory)][string]$RequestSha256
    )

    $problem = [Collections.Generic.List[string]]::new()
    $names = @($Attestation.PSObject.Properties.Name)
    if ($names -notcontains 'requestDigest') {
        $problem.Add('the attestation names no request digest, so nothing says which question it answers')
    } elseif (-not [string]::Equals([string]$Attestation.requestDigest.sha256, $RequestSha256, [StringComparison]::Ordinal)) {
        $problem.Add(('the attestation answers request {0}, and this bundle carries {1}' -f
            [string]$Attestation.requestDigest.sha256, $RequestSha256))
    }

    $people = @{}
    foreach ($role in 'translator', 'independentReviewer') {
        if ($names -notcontains $role) {
            $problem.Add("the attestation has no $role")
            continue
        }
        $entry = $Attestation.$role
        $entryNames = @($entry.PSObject.Properties.Name)
        $who = if ($entryNames -contains 'approvedBy') { ([string]$entry.approvedBy).Trim() } else { '' }
        $when = if ($entryNames -contains 'approvedAt') { ([string]$entry.approvedAt).Trim() } else { '' }
        if (-not $who) { $problem.Add("the $role is unnamed") }
        if (-not $when) {
            $problem.Add("the $role has no date")
        } else {
            $parsed = [datetime]::MinValue
            $styles = [Globalization.DateTimeStyles]::None
            if (-not [datetime]::TryParseExact($when, 'yyyy-MM-dd',
                    [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
                $problem.Add("the $role date '$when' is not a yyyy-MM-dd calendar date")
            } elseif ($parsed.Date -gt [datetime]::UtcNow.Date) {
                $problem.Add("the $role date '$when' has not happened yet")
            }
        }
        if ($who) { $people[$role] = $who }
    }
    if ($people.Count -eq 2) {
        $translator = [string]$people['translator']
        $reviewer = [string]$people['independentReviewer']
        # Case-insensitive on purpose: a second signature is a second person,
        # and a different capitalization of one name is the same person.
        if ([string]::Equals($translator, $reviewer, [StringComparison]::OrdinalIgnoreCase)) {
            $problem.Add("the independent reviewer '$reviewer' is the translator; a second signature is a second person")
        }
    }
    return [pscustomobject]@{ Ok = ($problem.Count -eq 0); Detail = ($problem -join '; ') }
}

function Read-LocalizationAnswer {
    <#
    .SYNOPSIS
        Every answer a returned bundle carries, keyed by row identity.
    .DESCRIPTION
        A row is answered when its translation is non-empty. A row present in
        the bundle but left blank is not an answer, which is what lets a
        partial return be re-exported with exactly the unanswered rows reopened
        rather than the whole language restarted.

        Documents are files rather than fields, so their answer is the file's
        own text at the path the request placed it.
    .OUTPUTS
        [hashtable] identity -> translated text
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$BundleRoot)

    $answer = @{}
    if (-not [IO.Directory]::Exists($BundleRoot)) { return $answer }
    $requestPath = Resolve-LocalizationPath -Root $BundleRoot -Relative 'request.json'
    if (-not [IO.File]::Exists($requestPath)) { return $answer }
    $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($requestPath))
    if ($request.format -cnotin @('Json', 'Csv', 'Xliff')) { throw "Unavailable localization codec: $($request.format)" }
    $expected = @{}
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $request.rows) {
        if ($expected.ContainsKey([string]$row.id)) { throw "Duplicate request row: $($row.id)" }
        $expected[[string]$row.id] = $row
    }
    foreach ($group in @($request.rows | Group-Object file)) {
        $path = Resolve-LocalizationPath -Root $BundleRoot -Relative $group.Name
        if (-not [IO.File]::Exists($path)) { continue }
        if ($group.Group[0].kind -ceq 'document') {
            if ($group.Count -ne 1) { throw 'A document file must have exactly one row.' }
            $text = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
            if ($text.Trim()) { $answer[[string]$group.Group[0].id] = $text }
            continue
        }
        foreach ($entry in @(Read-LocalizationEntry -Path $path -Format $request.format)) {
            $id = [string]$entry.id
            if (-not $expected.ContainsKey($id) -or $expected[$id].file -cne $group.Name) { throw "Unrequested answer row: $id" }
            if (-not $seen.Add($id)) { throw "Duplicate answer row: $id" }
            if ($entry.translation -isnot [string]) { throw "Answer must be a string: $id" }
            if ([string]$entry.english -cne [string]$expected[$id].english) { throw "Answer changed the source text: $id" }
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.translation)) { $answer[$id] = [string]$entry.translation }
        }
    }
    return $answer
}

function Get-LocalizationRowState {
    <#
    .SYNOPSIS
        Whether each row is carried, changed, or new.
    .DESCRIPTION
        Carried means the English is byte-identical to the round that produced
        the answer already in hand, so nobody is asked to look at it again.
        Changed means the English moved under an existing answer. New means no
        previous round covered it, or a previous round left it blank -- an
        unanswered row is not a settled one, however many times it was sent.
    .OUTPUTS
        [hashtable] identity -> ordered state, previousSourceSha256, previousEnglish, previousTranslation
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [AllowNull()]$PreviousRequest,
        [Collections.IDictionary]$Answer = @{}
    )

    $previous = @{}
    if ($null -ne $PreviousRequest) {
        foreach ($entry in @($PreviousRequest.rows)) { $previous[[string]$entry.id] = $entry }
    }
    $state = @{}
    foreach ($current in $Row) {
        $id = [string]$current.id
        $translation = if ($Answer.Contains($id)) { [string]$Answer[$id] } else { '' }
        $known = if ($previous.ContainsKey($id)) { $previous[$id] } else { $null }
        $previousHash = if ($null -ne $known) { [string]$known.sourceSha256 } else { '' }
        $previousEnglish = if ($null -ne $known -and
            @($known.PSObject.Properties.Name) -contains 'english') { [string]$known.english } else { '' }
        $value = if (-not $translation) {
            'new'
        } elseif ([string]::Equals($previousHash, [string]$current.sourceSha256, [StringComparison]::Ordinal)) {
            'carried'
        } else {
            'changed'
        }
        $state[$id] = [ordered]@{
            state = $value
            previousSourceSha256 = $previousHash
            previousEnglish = $previousEnglish
            previousTranslation = $translation
        }
    }
    return $state
}


function Resolve-LocalizationPath {
    <#
    .SYNOPSIS
        Resolve a confined exchange path without following links.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Root, [string]$Relative)
    if (-not $Relative -or $Relative -match '(^[\\/]|\\|:|(^|/)\.\.(/|$))') { throw "Invalid localization path: $Relative" }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $cursor = $path
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked localization path: $path" }
        $cursor = Split-Path -Parent $cursor
    }
    return $path
}

function Assert-LocalizationYamlCodec {
    <#
    .SYNOPSIS
        Require the real YAML reader and writer before processing project fields.
    #>
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) -or
        -not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        Import-Module powershell-yaml -Global -ErrorAction Stop
    }
}

function Get-LocalizationMessageHash {
    <#
    .SYNOPSIS
        Hash the complete source-owned message contract used by the compiler.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Key, $Message)
    # Match the compiler's semantic source projection, including branch selectors
    # and placeholder contracts. Compiler round-trip tests guard the wire format.
    function ConvertTo-MessageOrderedValue {
        param([AllowNull()]$Value)
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
        if ($Value -is [Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($name in @($Value.Keys | Sort-Object)) { $result[$name] = ConvertTo-MessageOrderedValue $Value[$name] }
            return $result
        }
        if ($Value -is [Collections.IEnumerable]) { return ,@($Value | ForEach-Object { ConvertTo-MessageOrderedValue $_ }) }
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) { $result[$property.Name] = ConvertTo-MessageOrderedValue $property.Value }
        return $result
    }
    $record = [ordered]@{ key = $Key; contract = ConvertTo-MessageOrderedValue $Message }
    return Get-TextSha256 -Text (((ConvertTo-Json -InputObject $record -Depth 20).Replace("`r`n", "`n")).TrimEnd() + "`n")
}

function Read-LocalizationEntry {
    <#
    .SYNOPSIS
        Read a JSON, CSV, or XLIFF 2.0 answer table.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Path, [ValidateSet('Json', 'Csv', 'Xliff')][string]$Format)
    switch -CaseSensitive ($Format) {
        'Json' { return @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))).entries) }
        'Csv' { return @(ConvertFrom-Csv -InputObject ([IO.File]::ReadAllText($Path))) }
        'Xliff' {
            $settings = [Xml.XmlReaderSettings]::new(); $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $reader = [Xml.XmlReader]::Create($Path, $settings)
            try { $document = [Xml.XmlDocument]::new(); $document.XmlResolver = $null; $document.Load($reader) }
            finally { $reader.Dispose() }
            if ($document.DocumentElement.LocalName -cne 'xliff' -or $document.DocumentElement.GetAttribute('version') -cne '2.0') { throw 'Expected XLIFF 2.0.' }
            return @($document.SelectNodes('//*[local-name()="unit"]') | ForEach-Object {
                $segment = $_.SelectSingleNode('./*[local-name()="segment"]')
                if (-not $segment) { throw 'XLIFF unit has no segment.' }
                $source = $segment.SelectSingleNode('./*[local-name()="source"]')
                $target = $segment.SelectSingleNode('./*[local-name()="target"]')
                if (-not $source -or -not $target) { throw 'XLIFF segment requires source and target.' }
                [pscustomobject]@{ id = $_.GetAttribute('id'); english = $source.InnerText; translation = $target.InnerText }
            })
        }
    }
}

function Write-LocalizationEntry {
    <#
    .SYNOPSIS
        Write a real table in the selected interchange format.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The exporter confirms the complete destination before writing its codec files.')]
    param([string]$Path, [ValidateSet('Json', 'Csv', 'Xliff')][string]$Format, [string]$Locale, [object[]]$Entries)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $text = switch -CaseSensitive ($Format) {
        'Json' { ConvertTo-Json -InputObject ([ordered]@{ locale = $Locale; entries = $Entries }) -Depth 30 }
        'Csv' { (@($Entries | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation) -join "`n") }
        'Xliff' {
            $builder = [Text.StringBuilder]::new()
            $settings = [Xml.XmlWriterSettings]::new(); $settings.OmitXmlDeclaration = $true; $settings.Indent = $true
            $writer = [Xml.XmlWriter]::Create($builder, $settings)
            try {
                $writer.WriteStartElement('xliff', 'urn:oasis:names:tc:xliff:document:2.0')
                $writer.WriteAttributeString('version', '2.0'); $writer.WriteAttributeString('srcLang', 'en-US'); $writer.WriteAttributeString('trgLang', $Locale)
                $writer.WriteStartElement('file'); $writer.WriteAttributeString('id', 'localization')
                foreach ($entry in $Entries) {
                    $writer.WriteStartElement('unit'); $writer.WriteAttributeString('id', [string]$entry.id)
                    $writer.WriteStartElement('segment')
                    $writer.WriteElementString('source', [string]$entry.english); $writer.WriteElementString('target', [string]$entry.translation)
                    $writer.WriteEndElement(); $writer.WriteEndElement()
                }
                $writer.WriteEndElement(); $writer.WriteEndElement(); $writer.Flush()
            } finally { $writer.Dispose() }
            $builder.ToString()
        }
    }
    [IO.File]::WriteAllText($Path, $text.Replace("`r`n", "`n").TrimEnd() + "`n", [Text.UTF8Encoding]::new($false))
}

function Set-LocalizationYamlValue {
    <#
    .SYNOPSIS
        Set a translated project scalar in its locale map.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes only the in-memory staged YAML document.')]
    param($Document, [string]$Pointer, [string]$Locale, [string]$Text)
    $segments = @($Pointer.TrimStart('/').Split('/') | ForEach-Object { $_.Replace('~1', '/').Replace('~0', '~') })
    $node = $Document
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $segment = $segments[$i]
        if ($segment -match '^([^=]+)=(.+)$') {
            $key = $Matches[1]; $value = $Matches[2]
            $matching = @($node | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_[$key] -ceq $value })
            if ($matching.Count -ne 1) { throw "Ambiguous project pointer: $Pointer" }
            $node = $matching[0]
        } elseif ($node -is [Collections.IList] -and $segment -match '^\d+$') { $node = $node[[int]$segment] }
        elseif ($node -is [Collections.IDictionary] -and $node.Contains($segment)) { $node = $node[$segment] }
        else { throw "Unknown project pointer: $Pointer" }
    }
    $field = $segments[-1]
    if ($field -cnotin @('displayName', 'description') -or $node -isnot [Collections.IDictionary] -or -not $node.Contains($field)) { throw "Not a project display scalar: $Pointer" }
    $map = $field + 'Localized'
    if (-not $node.Contains($map)) { $node[$map] = [ordered]@{} }
    if ($node[$map] -isnot [Collections.IDictionary]) { throw "Invalid project locale map: $Pointer" }
    $node[$map][$Locale] = $Text.Normalize([Text.NormalizationForm]::FormC)
}

Export-ModuleMember -Function Get-LocalizationExchangeSchema, Get-TextSha256, New-LocalizationRow,
    Get-TerminologyRow, Get-MessageRow, Get-DocumentRow, Get-ProjectScalarRow, Get-YamlPointerValue,
    Get-LocalizationProjectSource, Get-LocalizationRow, Get-LocalizationRequestDigest, Test-LocalizationAttestation,
    Read-LocalizationAnswer, Get-LocalizationRowState, Get-LocalizationMessageHash, Assert-LocalizationYamlCodec,
    Resolve-LocalizationPath, Read-LocalizationEntry, Write-LocalizationEntry, Set-LocalizationYamlValue
