<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 429aa9e5-4b47-42a5-adc9-b48244e14f6a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostics self-contained globalization pester
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
    Guards that automation/Get-SystemDiagnostic.ps1 runs as a single file.
.DESCRIPTION
    The console diagnostic rung downloads that one script into a guest's /tmp
    and runs it there, so the script may load no module. It carries copies of
    the log-level cascade, the operator-message renderer and the en-US text of
    its messages instead. These tests run the script alone in an empty folder
    and hold every copy equal to the source it was taken from: the compiled
    en-US catalog, the renderer in Test.Catalog.psm1, the resolver in
    Test.Locale.psm1 and the formatter in Yuruna.Globalization.psm1.

    The functions under test are defined from the script's own text, so the
    tests exercise the copy the script ships rather than a re-typed one.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:DiagnosticPath = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'
    $script:EmbedTool = Join-Path $script:RepoRoot 'tools/Update-SystemDiagnosticText.ps1'
    $script:CatalogRoot = Join-Path $script:RepoRoot 'globalization/generated/powershell'
    $script:Pwsh = (Get-Process -Id $PID).Path
    Import-Module (Join-Path $PSScriptRoot 'Test.Catalog.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Force -DisableNameChecking

    $parseErrors = $null
    $script:DiagnosticAst = [System.Management.Automation.Language.Parser]::ParseFile($script:DiagnosticPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw "Get-SystemDiagnostic.ps1 does not parse: $($parseErrors[0].Message)" }

    foreach ($name in @(
            'Get-DiagnosticLocaleManifest', 'ConvertTo-DiagnosticLocaleTag', 'Resolve-DiagnosticSupportedLocale',
            'Get-DiagnosticOperatorLocale', 'Get-DiagnosticMessageTable', 'Get-DiagnosticEmbeddedMessage',
            'Get-DiagnosticPluralCategory', 'Format-DiagnosticNumber', 'Format-DiagnosticArgument',
            'Format-DiagnosticSegment', 'Format-YurunaOperatorMessage', 'Invoke-DiagnosticBoundedCommand',
            'Invoke-Tool', 'Invoke-WithDeadline', 'Test-ExecutableFile', 'Add-Problem',
            'Get-DiagnosticUtmctlListing', 'Resolve-DiagnosticEvidenceRoot', 'Get-DiagnosticFileTail')) {
        $definition = $script:DiagnosticAst.Find({ param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $definition) { throw "Get-SystemDiagnostic.ps1 no longer defines $name." }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function Reset-DiagnosticRenderer {
        <#
        .SYNOPSIS
            Point the script's renderer at a root and forget what it cached.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Resets in-memory test state only.')]
        [CmdletBinding()]
        param([AllowEmptyString()][string]$Root, [string]$Locale)
        $script:DiagnosticTextRoot = $Root
        $script:DiagnosticLocaleManifest = $null
        $script:DiagnosticOperatorLocale = $null
        $script:DiagnosticMessageTables = @{}
        $script:DiagnosticEmbeddedMessages = $null
        if ($Locale) {
            $direction = (Get-DiagnosticLocaleManifest).Direction[$Locale]
            $script:DiagnosticOperatorLocale = @{ ResolvedTag = $Locale; Direction = $direction }
        }
    }

    function Get-UsedMessageKey {
        <#
        .SYNOPSIS
            Every literal key the script passes to Format-YurunaOperatorMessage, sorted ordinally.
        #>
        [CmdletBinding()]
        [OutputType([string[]])]
        param()
        $keys = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        $calls = $script:DiagnosticAst.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Format-YurunaOperatorMessage' }, $true)
        foreach ($call in $calls) {
            $elements = $call.CommandElements
            for ($index = 1; $index -lt $elements.Count - 1; $index++) {
                if ($elements[$index] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$index].ParameterName -eq 'Key') {
                    [void]$keys.Add($elements[$index + 1].Value)
                }
            }
        }
        return [string[]]@($keys)
    }

    function ConvertTo-CanonicalJson {
        <#
        .SYNOPSIS
            One catalog entry as JSON with every dictionary's keys in ordinal order.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([AllowNull()]$Value)
        $sort = {
            param($Item)
            if ($Item -is [System.Collections.IDictionary]) {
                $names = [string[]]@($Item.Keys)
                [Array]::Sort($names, [StringComparer]::Ordinal)
                $sorted = [ordered]@{}
                foreach ($name in $names) { $sorted[$name] = & $sort $Item[$name] }
                return $sorted
            }
            if ($Item -is [System.Collections.IList] -and $Item -isnot [string]) {
                return , @(foreach ($element in $Item) { & $sort $element })
            }
            return $Item
        }
        return (ConvertTo-Json -InputObject (& $sort $Value) -Depth 32 -Compress)
    }

    function Get-SampleArgument {
        <#
        .SYNOPSIS
            A value for every argument a compiled entry declares, by its type.
        #>
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([AllowNull()]$Entry)
        $sample = @{}
        $visit = {
            param($Node)
            if ($Node -is [System.Collections.IDictionary]) {
                if ($Node.Contains('arg')) {
                    $sample[[string]$Node['arg']] = switch ([string]$Node['type']) {
                        'integer' { 1234567 }
                        'decimal' { -9876.5 }
                        'duration' { 5400 }
                        'datetime' { [datetime]::new(2026, 9, 30, 12, 34, 56, [DateTimeKind]::Utc) }
                        default { "value of $($Node['arg'])" }
                    }
                }
                foreach ($child in $Node.Values) { & $visit $child }
            } elseif ($Node -is [System.Collections.IList] -and $Node -isnot [string]) {
                foreach ($child in $Node) { & $visit $child }
            }
        }
        & $visit $Entry
        return $sample
    }
}

Describe 'Get-SystemDiagnostic.ps1 loads nothing beside itself' {
    It 'imports no module and dot-sources no file' {
        $imports = @($script:DiagnosticAst.FindAll({ param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('Import-Module', 'ipmo') }, $true))
        $dotSourced = @($script:DiagnosticAst.FindAll({ param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true))
        $imports.Count | Should -Be 0 -Because 'the console rung runs this file with nothing beside it'
        $dotSourced.Count | Should -Be 0
        @($script:DiagnosticAst.UsingStatements).Count | Should -Be 0
    }

    It 'defines every Yuruna module command it calls, except runners it uses only when a caller loaded them' {
        $moduleCommand = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($folder in @('automation', 'test/modules', 'host')) {
            foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot $folder) -Filter '*.psm1' -File -Recurse) {
                $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                foreach ($definition in $moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                    [void]$moduleCommand.Add($definition.Name)
                }
            }
        }
        $defined = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($definition in $script:DiagnosticAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            [void]$defined.Add($definition.Name)
        }
        $optional = @('Invoke-UtmctlProbe', 'Invoke-BoundedNativeCommand', 'Test-BoundedNativeResultComplete')
        $called = @($script:DiagnosticAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        # A module may wrap a built-in cmdlet under its own name; the script
        # reaches the built-in, which needs no import.
        $missing = @($called | Where-Object {
                $moduleCommand.Contains($_) -and -not $defined.Contains($_) -and $_ -notin $optional -and
                -not (Get-Command -Name $_ -CommandType Cmdlet -ErrorAction SilentlyContinue)
            })
        $missing | Should -BeNullOrEmpty -Because 'a command from a module the script cannot import fails the moment it runs'
        $source = [IO.File]::ReadAllText($script:DiagnosticPath)
        foreach ($name in $optional) {
            $source | Should -Match ("Get-Command -Name $name\b") -Because "$name may be called only after the script confirmed a caller loaded it"
        }
    }

    It 'produces a complete report from a folder that holds nothing else' {
        $solo = Join-Path $TestDrive 'solo'
        $null = New-Item -ItemType Directory -Path $solo
        $copy = Join-Path $solo 'Get-SystemDiagnostic.ps1'
        Copy-Item -LiteralPath $script:DiagnosticPath -Destination $copy

        $run = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 300 -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $copy, '-SkipDocker', '-SkipKube',
            '-CheckoutRoot', (Join-Path $TestDrive 'no-checkout'))

        $run.TimedOut | Should -BeFalse
        $run.ExitCode | Should -Be 0
        $text = "$($run.StdOut)`n$($run.StdErr)"
        $text | Should -Not -Match 'is not recognized as a name of a cmdlet'
        $text | Should -Not -Match 'was not loaded because no valid module file was found'
        $text | Should -Match 'not applicable: checkout evidence is unavailable'
        $text | Should -Not -Match 'Cannot bind argument to parameter .Path. because it is an empty string'
        $unrendered = @(Get-UsedMessageKey | Where-Object { $text.Contains($_) })
        $unrendered | Should -BeNullOrEmpty -Because 'a key printed in place of its message means the embedded text did not load'
        $summary = [regex]::Match($run.StdOut, '(?ms)^===YURUNA-DIAG-JSON-BEGIN===\r?\n(.*?)\r?\n===YURUNA-DIAG-JSON-END===')
        $summary.Success | Should -BeTrue
        $problems = $summary.Groups[1].Value | ConvertFrom-Json -AsHashtable
        $problems.schema | Should -Be 'yuruna.diagnostic.problems/v1'
        $problems.byClass.Keys | Should -Not -Contain 'DIAG.section-aborted'
    }
}

Describe 'standalone diagnostic checkout evidence is independent of its file location' {
    BeforeEach {
        $script:FixtureCheckout = Join-Path $TestDrive 'checkout'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FixtureCheckout 'automation') -Force
        [IO.File]::WriteAllText((Join-Path $script:FixtureCheckout 'VERSION'), 'fixture-framework-version')
        $script:FixtureHome = Join-Path $TestDrive 'home'
        $homeCheckout = Join-Path $script:FixtureHome 'yuruna'
        $null = New-Item -ItemType Directory -Path (Join-Path $homeCheckout 'automation') -Force
        [IO.File]::WriteAllText((Join-Path $homeCheckout 'VERSION'), 'fixture-home-version')
    }

    It 'uses an explicit validated checkout even when the script was downloaded elsewhere' {
        Resolve-DiagnosticEvidenceRoot -CheckoutRoot $script:FixtureCheckout -ScriptDirectory '/tmp' -HomeDirectory '' |
            Should -BeExactly $script:FixtureCheckout
    }

    It 'discovers only the adjacent checkout or the known home checkout' {
        Resolve-DiagnosticEvidenceRoot -CheckoutRoot '' -ScriptDirectory (Join-Path $script:FixtureCheckout 'automation') -HomeDirectory $script:FixtureHome |
            Should -BeExactly $script:FixtureCheckout
        Resolve-DiagnosticEvidenceRoot -CheckoutRoot '' -ScriptDirectory (Join-Path $TestDrive 'download') -HomeDirectory $script:FixtureHome |
            Should -BeExactly (Join-Path $script:FixtureHome 'yuruna')
    }

    It 'does not treat the parent of a copied script as a checkout' {
        Resolve-DiagnosticEvidenceRoot -CheckoutRoot '' -ScriptDirectory (Join-Path $TestDrive 'download') -HomeDirectory '' |
            Should -BeNullOrEmpty
    }

    It 'does not replace an invalid explicit root with a different checkout' {
        Resolve-DiagnosticEvidenceRoot -CheckoutRoot (Join-Path $TestDrive 'missing') -ScriptDirectory (Join-Path $script:FixtureCheckout 'automation') -HomeDirectory $script:FixtureHome |
            Should -BeNullOrEmpty
    }

    It 'rejects filesystem roots and files as evidence roots' {
        Resolve-DiagnosticEvidenceRoot -CheckoutRoot ([IO.Path]::GetPathRoot($script:FixtureCheckout)) -ScriptDirectory '' -HomeDirectory '' |
            Should -BeNullOrEmpty
        Resolve-DiagnosticEvidenceRoot -CheckoutRoot (Join-Path $script:FixtureCheckout 'VERSION') -ScriptDirectory '' -HomeDirectory '' |
            Should -BeNullOrEmpty
    }

    It 'rejects a linked evidence root rather than traversing another tree' -Skip:($IsWindows) {
        $link = Join-Path $TestDrive 'linked-checkout'
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $script:FixtureCheckout
        Resolve-DiagnosticEvidenceRoot -CheckoutRoot $link -ScriptDirectory '' -HomeDirectory '' |
            Should -BeNullOrEmpty
    }

    It 'collects phase logs and project versions from the supplied checkout with no adjacent modules' {
        $project = Join-Path $script:FixtureCheckout 'project'
        $phase = Join-Path $project '.yuruna/localhost/components'
        $null = New-Item -ItemType Directory -Path $phase -Force
        [IO.File]::WriteAllText((Join-Path $project 'VERSION'), 'fixture-project-version')
        [IO.File]::WriteAllText((Join-Path $phase 'docker.stderr.log'), 'fixture-phase-stream-evidence')
        $solo = Join-Path $TestDrive 'download'
        $null = New-Item -ItemType Directory -Path $solo -Force
        $copy = Join-Path $solo 'Get-SystemDiagnostic.ps1'
        Copy-Item -LiteralPath $script:DiagnosticPath -Destination $copy

        $run = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 300 -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $copy, '-SkipDocker', '-SkipKube', '-CheckoutRoot', $script:FixtureCheckout)

        $run.TimedOut | Should -BeFalse
        $run.ExitCode | Should -Be 0
        $run.StdOut | Should -Match 'fixture-phase-stream-evidence'
        $run.StdOut | Should -Match 'fixture-framework-version'
        $run.StdOut | Should -Match 'fixture-project-version'
        $run.StdOut | Should -Not -Match 'DIAG.section-aborted'
    }
}

Describe 'phase evidence reads fixed byte ranges' {
    It 'reads only the last capped bytes of a large phase log' {
        $path = Join-Path $TestDrive 'large.stderr.log'
        [IO.File]::WriteAllText($path, ('x' * 131072) + 'retained-tail', [Text.UTF8Encoding]::new($false))
        $tail = Get-DiagnosticFileTail -Path $path
        [Text.Encoding]::UTF8.GetByteCount($tail) | Should -Be 65536
        $tail | Should -Match 'retained-tail$'
        Get-DiagnosticFileTail -Path $path -MaximumBytes 8 | Should -BeExactly 'ned-tail'
    }

    It 'keeps an empty log empty and recognizes a short UTF-16 log' {
        $path = Join-Path $TestDrive 'small.stderr.log'
        [IO.File]::WriteAllText($path, '')
        Get-DiagnosticFileTail -Path $path | Should -BeExactly ''
        $content = 'short unicode: ' + [char]0x00e7
        [IO.File]::WriteAllText($path, $content, [Text.Encoding]::Unicode)
        Get-DiagnosticFileTail -Path $path | Should -BeExactly $content
    }
}

Describe 'the embedded en-US text is the compiled catalog''s' {
    BeforeEach { Reset-DiagnosticRenderer -Root '' }

    It 'embeds exactly the messages the script prints' {
        $embedded = [string[]]@((Get-DiagnosticEmbeddedMessage).Keys)
        [Array]::Sort($embedded, [StringComparer]::Ordinal)
        ($embedded -join "`n") | Should -BeExactly ((Get-UsedMessageKey) -join "`n")
    }

    It 'embeds each message exactly as the compiler wrote it' {
        $catalog = Import-PowerShellDataFile -LiteralPath (Join-Path $script:CatalogRoot 'en-US.automation.psd1') -SkipLimitCheck
        $embedded = Get-DiagnosticEmbeddedMessage
        $drift = @(foreach ($key in Get-UsedMessageKey) {
                if ((ConvertTo-CanonicalJson $embedded[$key]) -cne (ConvertTo-CanonicalJson $catalog[$key])) { $key }
            })
        $drift | Should -BeNullOrEmpty -Because 'run tools/Update-SystemDiagnosticText.ps1 after changing a message the script prints'
    }

    It 'is reported current by its generator' {
        $output = & $script:Pwsh -NoProfile -NonInteractive -File $script:EmbedTool -Check 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'is reported stale by its generator, and then rewritten, after a printed message changes' {
        $catalogCopy = Join-Path $TestDrive 'catalog'
        $null = New-Item -ItemType Directory -Path $catalogCopy
        $catalogText = [IO.File]::ReadAllText((Join-Path $script:CatalogRoot 'en-US.automation.psd1'))
        $line = [regex]::Matches($catalogText, "(?m)^    '(automation\.[a-z0-9_]+)' = '([^'\r\n]+)'\r?$") |
            Where-Object { $_.Groups[1].Value -in (Get-UsedMessageKey) } | Select-Object -First 1
        $line | Should -Not -BeNullOrEmpty
        $key = $line.Groups[1].Value
        $changed = $catalogText.Replace($line.Value.TrimEnd("`r"), "    '$key' = 'Changed fixture text.'")
        [IO.File]::WriteAllText((Join-Path $catalogCopy 'en-US.automation.psd1'), $changed)
        $scriptCopy = Join-Path $TestDrive 'Get-SystemDiagnostic.ps1'
        Copy-Item -LiteralPath $script:DiagnosticPath -Destination $scriptCopy

        $stale = & $script:Pwsh -NoProfile -NonInteractive -File $script:EmbedTool -Check -Path $scriptCopy -CatalogRoot $catalogCopy 2>&1
        $staleExit = $LASTEXITCODE
        $unchanged = [IO.File]::ReadAllText($scriptCopy) -ceq [IO.File]::ReadAllText($script:DiagnosticPath)
        $null = & $script:Pwsh -NoProfile -NonInteractive -File $script:EmbedTool -Path $scriptCopy -CatalogRoot $catalogCopy -Quiet 2>&1
        $writeExit = $LASTEXITCODE
        $null = & $script:Pwsh -NoProfile -NonInteractive -File $script:EmbedTool -Check -Path $scriptCopy -CatalogRoot $catalogCopy -Quiet 2>&1
        $recheckExit = $LASTEXITCODE

        $staleExit | Should -Be 1
        ($stale -join "`n") | Should -Match ([regex]::Escape("STALE: changed $key"))
        $unchanged | Should -BeTrue -Because '-Check must not write'
        $writeExit | Should -Be 0
        $recheckExit | Should -Be 0
        $definition = [System.Management.Automation.Language.Parser]::ParseFile($scriptCopy, [ref]$null, [ref]$null).Find({ param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DiagnosticEmbeddedMessage' }, $true)
        try {
            $script:DiagnosticEmbeddedMessages = $null
            $rewritten = & ([scriptblock]::Create($definition.Extent.Text + "`nGet-DiagnosticEmbeddedMessage"))
        } finally { Reset-DiagnosticRenderer -Root '' }
        $rewritten[$key] | Should -BeExactly 'Changed fixture text.'
        $rewritten.Count | Should -Be @(Get-UsedMessageKey).Count
    }
}

Describe 'the script renders what the shared renderer renders' {
    AfterAll { Reset-DiagnosticRenderer -Root '' }

    It 'renders every message the script prints in <Locale>' -TestCases @(
        @{ Locale = 'en-US' }, @{ Locale = 'pt-BR' }, @{ Locale = 'zh-CN' }, @{ Locale = 'he-IL' }
    ) {
        param($Locale)
        Reset-DiagnosticRenderer -Root $script:RepoRoot -Locale $Locale
        $catalog = Get-CatalogDomain -Locale $Locale -Domain automation
        $fallback = Get-CatalogDomain -Locale en-US -Domain automation
        $mismatch = @(foreach ($key in Get-UsedMessageKey) {
                $entry = if ($catalog.ContainsKey($key)) { $catalog[$key] } else { $fallback[$key] }
                $sample = Get-SampleArgument -Entry $entry
                $expected = Format-CatalogMessage -Key $key -Arguments $sample -Locale $Locale
                $actual = Format-YurunaOperatorMessage -Key $key -Arguments $sample
                if ($actual -cne $expected) { "${key}: '$actual' <> '$expected'" }
            })
        $mismatch | Should -BeNullOrEmpty
    }

    It 'renders the embedded en-US text when no catalog is beside it' {
        Reset-DiagnosticRenderer -Root (Join-Path $TestDrive 'empty')
        (Get-DiagnosticOperatorLocale).ResolvedTag | Should -Be 'en-US'
        $catalog = Get-CatalogDomain -Locale en-US -Domain automation
        $mismatch = @(foreach ($key in Get-UsedMessageKey) {
                $sample = Get-SampleArgument -Entry $catalog[$key]
                $expected = Format-CatalogMessage -Key $key -Arguments $sample -Locale en-US
                $actual = Format-YurunaOperatorMessage -Key $key -Arguments $sample
                if ($actual -cne $expected) { "${key}: '$actual' <> '$expected'" }
            })
        $mismatch | Should -BeNullOrEmpty
    }

    It 'returns the key itself for a message nobody ships' {
        Reset-DiagnosticRenderer -Root (Join-Path $TestDrive 'empty')
        Format-YurunaOperatorMessage -Key 'automation.no_such_fixture_message' | Should -BeExactly 'automation.no_such_fixture_message'
    }

    It 'keeps failed endpoint counts and targets in the network problem' {
        Reset-DiagnosticRenderer -Root $script:RepoRoot -Locale 'en-US'
        $message = Format-YurunaOperatorMessage -Key 'automation.operator_b6be1dbdabe6cc70' -Arguments @{
            count = '1'; count2 = '3'; join = 'mirror.example:443'
        }
        $message | Should -BeExactly 'NETWORK: 1/3 endpoint(s) unreachable: mirror.example:443'
    }

    It 'evaluates composite format bindings as Yuruna.Globalization does' {
        $context = Yuruna.Globalization\Get-YurunaOperatorLocale
        Reset-DiagnosticRenderer -Root $script:RepoRoot -Locale $context.ResolvedTag
        $key = 'automation.operator_634f2762ed20d183'
        $key | Should -BeIn (Get-UsedMessageKey)
        foreach ($case in @(
                @{ Values = @(7, 'neigh detail'); Bindings = @{ lASTEXITCODE = '0'; join = '1' } },
                @{ Values = @(1234567, 'x'); Bindings = @{ lASTEXITCODE = '0:N0'; join = '1,-8' } })) {
            $expected = Yuruna.Globalization\Format-YurunaOperatorMessage -Key $key -FormatValues $case.Values -FormatBindings $case.Bindings
            $actual = Format-YurunaOperatorMessage -Key $key -FormatValues $case.Values -FormatBindings $case.Bindings
            $actual | Should -BeExactly $expected
        }
    }

    It 'resolves config <Config> with process culture <Process> as New-LocaleContext does' -TestCases @(
        @{ Config = 'pt-BR'; Process = 'en-US' }
        @{ Config = 'auto'; Process = 'zh-CN' }
        @{ Config = 'auto'; Process = 'pt-PT' }
        @{ Config = 'auto'; Process = 'fr-FR' }
        @{ Config = 'iw'; Process = 'en-US' }
        @{ Config = 'xx-YY'; Process = 'pt-BR' }
        @{ Config = 'he-IL'; Process = 'pt-BR' }
    ) {
        param($Config, $Process)
        $root = Join-Path $TestDrive "locale-$Config-$Process"
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'test'), (Join-Path $root 'globalization') -Force
        [IO.File]::WriteAllText((Join-Path $root 'test/test.config.yml'), "language: `"$Config`"  # fixture`n")
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'globalization/locale-manifest.json') -Destination (Join-Path $root 'globalization')
        $before = [Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo($Process)
            Reset-DiagnosticRenderer -Root $root
            $actual = Get-DiagnosticOperatorLocale
        } finally { [Threading.Thread]::CurrentThread.CurrentUICulture = $before }
        $expected = New-LocaleContext -ConfigLanguage $Config -ProcessCulture $Process
        $actual.ResolvedTag | Should -BeExactly $expected.ResolvedTag
        $actual.Direction | Should -BeExactly $expected.Direction
    }

    It 'gives en-US the separators, plural rule and direction of the manifest when it has no manifest' {
        Reset-DiagnosticRenderer -Root (Join-Path $TestDrive 'empty')
        $builtIn = Get-DiagnosticLocaleManifest
        $real = Get-LocaleManifest
        $builtIn.Default | Should -BeExactly $real.Default
        $builtIn.MaxTagLength | Should -Be $real.MaxTagLength
        $builtIn.Direction['en-US'] | Should -BeExactly $real.Direction['en-US']
        $builtIn.PluralRule['en-US'] | Should -BeExactly $real.PluralRule['en-US']
        foreach ($field in 'Group', 'Decimal', 'GroupSize') {
            $builtIn.NumberFormat['en-US'][$field] | Should -Be $real.NumberFormat['en-US'][$field]
        }
    }

    It 'agrees with Test.Catalog on plural categories, numbers and isolated arguments in every locale' {
        Reset-DiagnosticRenderer -Root $script:RepoRoot
        $real = Get-LocaleManifest
        $mismatch = [System.Collections.Generic.List[string]]::new()
        foreach ($locale in $real.PluralRule.Keys) {
            foreach ($count in @(0, 1, 1.5, 2, 3, 1000000, -1)) {
                $expected = Get-PluralCategory -Locale $locale -Count $count
                $actual = Get-DiagnosticPluralCategory -Locale $locale -Count $count
                if ($actual -cne $expected) { $mismatch.Add("plural $locale $count") }
            }
        }
        foreach ($locale in $real.NumberFormat.Keys) {
            foreach ($value in @(0, 12, 1234, -1234567.891)) {
                foreach ($decimals in 0, 2) {
                    $expected = Format-CatalogNumber -Value $value -Locale $locale -Decimals $decimals
                    $actual = Format-DiagnosticNumber -Value $value -Locale $locale -Decimals $decimals
                    if ($actual -cne $expected) { $mismatch.Add("number $locale $value $decimals") }
                }
            }
            foreach ($type in 'integer', 'decimal', 'duration', 'datetime', 'detail') {
                $value = if ($type -eq 'datetime') { [datetime]::new(2026, 9, 30, 1, 2, 3, [DateTimeKind]::Utc) } elseif ($type -eq 'detail') { 'value' } else { 3725 }
                $expected = Format-CatalogArgument -Value $value -Type $type -Locale $locale
                $actual = Format-DiagnosticArgument -Value $value -Type $type -Locale $locale
                if ($actual -cne $expected) { $mismatch.Add("argument $locale $type") }
            }
        }
        $mismatch | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DiagnosticBoundedCommand bounds a command without any module' {
    It 'returns the output and exit status of a command that finishes' {
        $r = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 60 -ArgumentList @(
            '-NoProfile', '-Command', '[Console]::Write("fixture-out"); [Console]::Error.Write("fixture-err"); exit 3')
        $r.Started | Should -BeTrue
        $r.ExitCode | Should -Be 3
        $r.StdOut | Should -BeExactly 'fixture-out'
        $r.StdErr | Should -BeExactly 'fixture-err'
        $r.TimedOut | Should -BeFalse
        $r.DrainTimedOut | Should -BeFalse
        $r.OutputTruncated | Should -BeFalse
    }

    It 'stops a command at its cap and says so' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 2 -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 60')
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 15
        $r.Started | Should -BeTrue
        $r.TimedOut | Should -BeTrue
        $r.KillFailed | Should -BeFalse
        $r.ExitCode | Should -Be -1
    }

    It 'reports a command that cannot start instead of throwing' {
        $r = Invoke-DiagnosticBoundedCommand -FilePath (Join-Path $TestDrive 'no-such-command') -TimeoutSeconds 5
        $r.Started | Should -BeFalse
        $r.StartError | Should -Not -BeNullOrEmpty
    }

    It 'keeps only the capture cap of a long stream and reports the rest as dropped' {
        $r = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 60 -MaxCapturedChars 4096 -ArgumentList @(
            '-NoProfile', '-Command', '[Console]::Write([string]::new([char]120, 20000))')
        $r.ExitCode | Should -Be 0
        $r.OutputTruncated | Should -BeTrue
        $r.StdOut.Length | Should -Be 4096
    }

    It 'lists utmctl through it when no caller loaded a runner' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -in @('Invoke-BoundedNativeCommand', 'Invoke-UtmctlProbe') }
        Get-Command -Name Invoke-BoundedNativeCommand -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command -Name Invoke-UtmctlProbe -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $bin = Join-Path $TestDrive 'bin'
        $null = New-Item -ItemType Directory -Path $bin
        if ($IsWindows) {
            [IO.File]::WriteAllText((Join-Path $bin 'utmctl.cmd'), "@echo UUID Status Name`r`n@echo AAAA started one`r`n")
        } else {
            $standIn = Join-Path $bin 'utmctl'
            [IO.File]::WriteAllText($standIn, "#!/bin/sh`nprintf 'UUID Status Name\nAAAA started one\n'`n")
            & chmod +x $standIn
        }
        $savedPath = $env:PATH
        try {
            $env:PATH = $bin + [IO.Path]::PathSeparator + $savedPath
            Reset-DiagnosticRenderer -Root (Join-Path $TestDrive 'empty')
            $lines = @(Get-DiagnosticUtmctlListing -TimeoutSeconds 30)
        } finally { $env:PATH = $savedPath }
        $lines | Should -Be @('UUID Status Name', 'AAAA started one')
    }
}

Describe 'Invoke-Tool native diagnostics preserve evidence and classification' {
    BeforeEach {
        Reset-DiagnosticRenderer -Root (Join-Path $TestDrive 'no-catalog')
        $script:Problems = [Collections.Generic.List[string]]::new()
        $script:ProblemRecords = [Collections.Generic.List[hashtable]]::new()
        $script:LinuxPriv = @()
    }
    It 'captures zero, one and many native output lines without a PowerShell job: <Command>' -ForEach @(
        @{ Command = 'exit 0'; Expected = @() },
        @{ Command = '[Console]::WriteLine("one")'; Expected = @('one') },
        @{ Command = '[Console]::Write("one`r`ntwo`r`n`r`n")'; Expected = @('one', 'two', '') }
    ) {
        Mock Invoke-WithDeadline { throw 'Native tools must not start a PowerShell job.' }
        $lines = @(Invoke-Tool -Tool $script:Pwsh -ToolArgs @('-NoProfile', '-Command', $Command) -TimeoutSeconds 30 -ProblemTag 'FIXTURE.native')
        $lines.Count | Should -Be $Expected.Count
        if ($Expected.Count) { $lines | Should -Be $Expected }
        $script:Problems.Count | Should -Be 0
        Should -Invoke Invoke-WithDeadline -Times 0
    }
    It 'retains Unicode stdout and stderr and the existing nonzero problem class' {
        $lines = @(Invoke-Tool -Tool $script:Pwsh -ToolArgs @('-NoProfile', '-Command', '[Console]::WriteLine("Caf`u{e9} `u{6771}`u{4eac}"); [Console]::Error.WriteLine("denied `u{fc}"); exit 7') -TimeoutSeconds 30 -ProblemTag 'FIXTURE.native')
        $lines | Should -Be @("Caf`u{e9} `u{6771}`u{4eac}", "denied `u{fc}")
        $script:ProblemRecords.Count | Should -Be 1
        $script:ProblemRecords[0].class | Should -BeExactly 'FIXTURE.native'
        $script:ProblemRecords[0].message | Should -Match '7'
    }
    It 'passes paths and argument boundaries literally without shell evaluation' {
        $fixture = Join-Path $TestDrive "literal `u{fc} [1]; tool.ps1"
        'param([string]$Value); [Console]::Write($Value)' | Set-Content -LiteralPath $fixture -Encoding utf8
        $literal = 'space "quotes" $HOME; $(ignored) [x] ' + "`u{fc}"
        $lines = @(Invoke-Tool -Tool $script:Pwsh -ToolArgs @('-NoProfile', '-File', $fixture, $literal) -TimeoutSeconds 30)
        $lines | Should -Be @($literal)
    }
    It 'retains partial output and the timeout problem class' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $timeout = if ($IsWindows) { 10 } else { 2 }
        $lines = @(Invoke-Tool -Tool $script:Pwsh -ToolArgs @('-NoProfile', '-Command', '[Console]::WriteLine("before-hang"); Start-Sleep 60') -TimeoutSeconds $timeout -ProblemTag 'FIXTURE.timeout')
        $clock.Elapsed.TotalSeconds | Should -BeLessThan ($timeout + 13)
        $lines | Should -Contain 'before-hang'
        $script:ProblemRecords.Count | Should -Be 1
        $script:ProblemRecords[0].class | Should -BeExactly 'FIXTURE.timeout'
        $script:ProblemRecords[0].message | Should -Match ([string]$timeout)
    }
    It 'clearly marks incomplete native evidence with <Flag>' -ForEach @(
        @{ Flag = 'DrainTimedOut' }, @{ Flag = 'OutputTruncated' }, @{ Flag = 'KillFailed' }
    ) {
        $script:IncompleteFlag = $Flag
        Mock Invoke-DiagnosticBoundedCommand {
            $result = @{ Started = $true; ExitCode = 0; StdOut = 'prefix'; StdErr = ''; TimedOut = $false
                DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false; StartError = '' }
            $result[$script:IncompleteFlag] = $true
            return $result
        }
        $lines = @(Invoke-Tool -Tool $script:Pwsh -TimeoutSeconds 30 -ProblemTag 'FIXTURE.partial')
        $lines | Should -Contain 'prefix'
        ($lines -join "`n") | Should -Match "$Flag=True"
        $script:ProblemRecords[0].class | Should -BeExactly 'FIXTURE.partial'
    }
    It 'retains Windows batch shim interpreter semantics for <Extension>' -ForEach @(
        @{ Extension = '.cmd' }, @{ Extension = '.bat' }
    ) {
        $script:BatchPath = 'C:\fixture\tool' + $Extension
        Mock Get-Command { return [pscustomobject]@{ CommandType = 'Application'; Source = $script:BatchPath } } -ParameterFilter { $Name -eq 'fixture-batch' }
        Mock Test-ExecutableFile { return $true }
        Mock Invoke-WithDeadline { return @{ TimedOut = $false; Output = @('batch-output', 0) } }
        Mock Invoke-DiagnosticBoundedCommand { throw 'A batch shim requires interpreter dispatch.' }
        $lines = & {
            # Automatic platform variables are AllScope: forcing a test value
            # changes the inherited variable too, so restore it even on error.
            $savedWindows = $IsWindows
            try {
                Set-Variable -Name IsWindows -Value $true -Scope Local -Force
                @(Invoke-Tool -Tool 'fixture-batch' -TimeoutSeconds 30)
            } finally {
                Set-Variable -Name IsWindows -Value $savedWindows -Scope Local -Force
            }
        }
        $lines | Should -Be @('batch-output')
        Should -Invoke Invoke-WithDeadline -Times 1 -Exactly
        Should -Invoke Invoke-DiagnosticBoundedCommand -Times 0
    }
    It 'continues to use the scriptblock compatibility runner for a PowerShell function' {
        function Invoke-FixtureTool { 'unused' }
        Mock Invoke-WithDeadline { return @{ TimedOut = $false; Output = @('function-output', 0) } }
        Mock Invoke-DiagnosticBoundedCommand { throw 'Functions are not executable files.' }
        @(Invoke-Tool -Tool Invoke-FixtureTool -TimeoutSeconds 30) | Should -Be @('function-output')
        Should -Invoke Invoke-WithDeadline -Times 1 -Exactly
        Should -Invoke Invoke-DiagnosticBoundedCommand -Times 0
    }
}

Describe 'standalone native stream and descendant safety' {
    BeforeAll {
        $script:TreeFixture = Join-Path $TestDrive 'tree-fixture.ps1'
        @'
param([string]$PidPath, [switch]$ParentExits)
$info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
foreach ($argument in @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60')) { [void]$info.ArgumentList.Add($argument) }
$child = [Diagnostics.Process]::Start($info)
[IO.File]::WriteAllText($PidPath, [string]$child.Id)
[Console]::WriteLine('parent-prefix')
if (-not $ParentExits) { Start-Sleep -Seconds 60 }
'@ | Set-Content -LiteralPath $script:TreeFixture -Encoding utf8
    }
    It 'caps each stream while draining simultaneous native stdout and stderr' {
        $r = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 30 -MaxCapturedChars 4096 -ArgumentList @(
            '-NoProfile', '-Command', 'for($i=0;$i -lt 100;$i++){[Console]::Out.Write([string]::new([char]120,1000));[Console]::Error.Write([string]::new([char]121,1000))}')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeExactly ([string]::new([char]120, 4096))
        $r.StdErr | Should -BeExactly ([string]::new([char]121, 4096))
        $r.OutputTruncated | Should -BeTrue
        $r.DrainTimedOut | Should -BeFalse
    }
    It 'closes stdin so a native reader sees EOF' {
        $r = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 30 -ArgumentList @(
            '-NoProfile', '-Command', 'if($null -eq [Console]::ReadLine()){[Console]::Write("eof")}else{exit 4}')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeExactly 'eof'
    }
    It 'terminates its timed-out process tree and keeps the captured prefix' {
        $pidPath = Join-Path $TestDrive 'killed-child.pid'
        try {
            $timeout = if ($IsWindows) { 10 } else { 2 }
            $r = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds $timeout -ArgumentList @('-NoProfile', '-File', $script:TreeFixture, $pidPath)
            $r.TimedOut | Should -BeTrue
            $r.KillFailed | Should -BeFalse
            $r.StdOut | Should -Match 'parent-prefix'
            $childId = [int][IO.File]::ReadAllText($pidPath)
            $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
            if ($child) { $child.HasExited | Should -BeTrue }
        } finally {
            if (Test-Path -LiteralPath $pidPath) {
                $child = Get-Process -Id ([int][IO.File]::ReadAllText($pidPath)) -ErrorAction SilentlyContinue
                if ($child -and -not $child.HasExited) { $child.Kill($true) }
            }
        }
    }
    It 'reports an inherited stream held open after the immediate parent exits' {
        $pidPath = Join-Path $TestDrive 'orphan-child.pid'
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-DiagnosticBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 30 -ArgumentList @('-NoProfile', '-File', $script:TreeFixture, $pidPath, '-ParentExits')
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 15
            $r.ExitCode | Should -Be 0
            $r.TimedOut | Should -BeFalse
            $r.DrainTimedOut | Should -BeTrue
            $r.StdOut | Should -Match 'parent-prefix'
        } finally {
            if (Test-Path -LiteralPath $pidPath) {
                $child = Get-Process -Id ([int][IO.File]::ReadAllText($pidPath)) -ErrorAction SilentlyContinue
                if ($child -and -not $child.HasExited) { $child.Kill($true) }
            }
        }
    }
}
