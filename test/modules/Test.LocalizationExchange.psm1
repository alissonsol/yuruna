<#PSScriptInfo
.VERSION 2026.09.13
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
    param([Parameter(Mandatory)][string]$Root, [string]$SourceLocale = 'en-US')

    $rows = [Collections.Generic.List[object]]::new()
    $directory = Join-Path $Root ('globalization/catalogs/{0}' -f $SourceLocale)
    if (-not [IO.Directory]::Exists($directory)) { return $rows.ToArray() }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' | Sort-Object -Property Name)) {
        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName))
        $domain = [string]$catalog.domain
        foreach ($code in (Get-OrdinalSortedName -Name @($catalog.messages.PSObject.Properties.Name | Where-Object { $_ }))) {
            $entry = $catalog.messages.$code
            $names = @($entry.PSObject.Properties.Name)
            $text = if ($names -contains 'message') {
                [string]$entry.message
            } elseif ($names -contains 'plural') {
                $variants = $entry.plural.variants
                (@(Get-OrdinalSortedName -Name @($variants.PSObject.Properties.Name | Where-Object { $_ })) |
                    ForEach-Object { '{0}={1}' -f $_, [string]$variants.$_ }) -join "`n"
            } else { '' }
            $description = if ($names -contains 'description') { [string]$entry.description } else { '' }
            $rows.Add((New-LocalizationRow -Id ('message:{0}:{1}' -f $domain, $code) -Kind 'message' `
                        -File ('messages/{0}.json' -f $domain) -Pointer $code `
                        -English ("{0}`n{1}" -f $text, $description) -Context $description))
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
        The recorded source hash is the authority for whether a scalar moved,
        because it is what the project map gate already compares. The English
        text is read from the YAML for the translator's benefit; where the YAML
        reader is unavailable the row still travels with its identity and hash,
        which keeps a scalar from silently dropping out of the request.
    .OUTPUTS
        [object[]]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Locale)

    $rows = [Collections.Generic.List[object]]::new()
    $recordPath = Join-Path $ProjectRoot 'globalization/project-locale-source-hashes.json'
    if (-not [IO.File]::Exists($recordPath)) { return $rows.ToArray() }
    $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($recordPath))
    $canRead = [bool](Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)
    $cache = @{}
    foreach ($entry in @($record.entries)) {
        if ([string]$entry.locale -cne $Locale) { continue }
        $path = [string]$entry.path
        $pointer = [string]$entry.fieldPath
        $english = ''
        if ($canRead) {
            if (-not $cache.ContainsKey($path)) {
                $full = Join-Path $ProjectRoot $path
                $cache[$path] = if ([IO.File]::Exists($full)) {
                    ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($full)) -Ordered
                } else { $null }
            }
            $english = Get-YamlPointerValue -Document $cache[$path] -Pointer $pointer
        }
        # The recorded hash is what the project gate compares, so it stays the
        # row's source digest even when the scalar text could not be read.
        $row = New-LocalizationRow -Id ('project-scalar:{0}:{1}' -f $path, $pointer) -Kind 'project-scalar' `
            -Repo 'yuruna-project' -File 'project/display-map.json' -Pointer $pointer -English $english -Context $path
        $row.sourceSha256 = [string]$entry.sourceHash
        $rows.Add($row)
    }
    return $rows.ToArray()
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
    foreach ($segment in @($Pointer.Split('/') | Where-Object { $_ })) {
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
        $node = if ($node -is [Collections.IDictionary] -and $node.Contains($segment)) { $node[$segment] } else { $null }
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
    $rows.AddRange([object[]](Get-MessageRow -Root $Root -SourceLocale $SourceLocale))
    $rows.AddRange([object[]](Get-DocumentRow -Root $Root -ProjectRoot $ProjectRoot -Locale $Locale))
    $rows.AddRange([object[]](Get-ProjectScalarRow -ProjectRoot $ProjectRoot -Locale $Locale))

    $byId = @{}
    foreach ($row in $rows) { $byId[[string]$row.id] = $row }
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
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row)

    # Not `$row`: PowerShell variable names are case-insensitive, so a loop
    # variable spelled like its parameter destroys the collection it walks.
    $projection = foreach ($item in $Row) {
        [ordered]@{ id = [string]$item.id; kind = [string]$item.kind; sourceSha256 = [string]$item.sourceSha256 }
    }
    $canonical = ConvertTo-CanonicalApprovalJson -Value @($projection)
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
    foreach ($relative in @('glossary/terms.json', 'glossary/rulings.json', 'glossary/style-guide.json',
            'project/display-map.json')) {
        $path = Join-Path $BundleRoot $relative
        if (-not [IO.File]::Exists($path)) { continue }
        foreach ($entry in @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).entries)) {
            $names = @($entry.PSObject.Properties.Name)
            if ($names -notcontains 'id' -or $names -notcontains 'translation') { continue }
            $text = [string]$entry.translation
            if ($text) { $answer[[string]$entry.id] = $text }
        }
    }
    $messages = Join-Path $BundleRoot 'messages'
    if ([IO.Directory]::Exists($messages)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $messages -Filter '*.json')) {
            foreach ($entry in @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName))).entries)) {
                $names = @($entry.PSObject.Properties.Name)
                if ($names -notcontains 'id' -or $names -notcontains 'translation') { continue }
                $text = [string]$entry.translation
                if ($text) { $answer[[string]$entry.id] = $text }
            }
        }
    }
    $documents = Join-Path $BundleRoot 'documents'
    if ([IO.Directory]::Exists($documents)) {
        $prefix = [IO.Path]::GetFullPath($documents)
        foreach ($file in @(Get-ChildItem -LiteralPath $documents -Recurse -File)) {
            $relative = $file.FullName.Substring($prefix.Length).TrimStart([IO.Path]::DirectorySeparatorChar,
                [char]'/').Replace('\\', '/')
            $split = $relative.IndexOf('/')
            if ($split -le 0) { continue }
            $id = 'document:{0}:{1}' -f $relative.Substring(0, $split), $relative.Substring($split + 1)
            $text = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
            if ($text.Trim()) { $answer[$id] = $text }
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

Export-ModuleMember -Function Get-LocalizationExchangeSchema, Get-TextSha256, New-LocalizationRow,
    Get-TerminologyRow, Get-MessageRow, Get-DocumentRow, Get-ProjectScalarRow, Get-YamlPointerValue,
    Get-LocalizationRow, Get-LocalizationRequestDigest, Test-LocalizationAttestation,
    Read-LocalizationAnswer, Get-LocalizationRowState
