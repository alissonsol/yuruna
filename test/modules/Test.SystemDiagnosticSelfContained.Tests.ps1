<#PSScriptInfo
.VERSION 2026.09.30
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
            'Get-DiagnosticUtmctlListing')) {
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
            '-NoProfile', '-NonInteractive', '-File', $copy, '-SkipDocker', '-SkipKube', '-SkipProjectGaps')

        $run.TimedOut | Should -BeFalse
        $run.ExitCode | Should -Be 0
        $text = "$($run.StdOut)`n$($run.StdErr)"
        $text | Should -Not -Match 'is not recognized as a name of a cmdlet'
        $text | Should -Not -Match 'was not loaded because no valid module file was found'
        $unrendered = @(Get-UsedMessageKey | Where-Object { $text.Contains($_) })
        $unrendered | Should -BeNullOrEmpty -Because 'a key printed in place of its message means the embedded text did not load'
        $summary = [regex]::Match($run.StdOut, '(?ms)^===YURUNA-DIAG-JSON-BEGIN===\r?\n(.*?)\r?\n===YURUNA-DIAG-JSON-END===')
        $summary.Success | Should -BeTrue
        $problems = $summary.Groups[1].Value | ConvertFrom-Json -AsHashtable
        $problems.schema | Should -Be 'yuruna.diagnostic.problems/v1'
        $problems.byClass.Keys | Should -Not -Contain 'DIAG.section-aborted'
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
