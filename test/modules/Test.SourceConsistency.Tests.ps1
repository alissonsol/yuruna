<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42e220c4-9472-4e35-bf37-59a7e003196b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test consistency host guest seed pester
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
    Verify shared host, guest, and seed contracts without creating a VM.
.DESCRIPTION
    See https://yuruna.link/42e220c4-000a for family boundaries and exceptions.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ProjectRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
    $script:LinkRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna.link'
    $script:AmisadRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'amisad.dev'
    if (-not (Test-Path -LiteralPath $script:AmisadRoot -PathType Container)) {
        $script:AmisadRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'alius-git/amisad.dev'
    }
    $script:SeedRoot = Join-Path $script:RepoRoot 'host/vmconfig'
    # SQL comments open with `--` and CSS comments with `/* */`, so the `#` and
    # `//` patterns elsewhere in this file never see them. A line that starts
    # a dash run followed by whitespace, or ends with one, is a decorative rule
    # or title; the native REGION form is the replacement. A CSS custom
    # property such as `--fg-header` is not a rule, because no whitespace
    # follows its dashes.
    $script:SqlCssDividerPattern = '(?m)^[ \t]*(?:--[ \t]*-{4,}[ \t]*$|--[ \t]+--+[ \t]+(?!REGION:)\S|--[ \t]+(?!REGION:)[^\r\n]*[ \t]-{5,}[ \t]*$|/\*[ \t]*-{2,}(?=[ \t]|$)|/\*[^\r\n]*[ \t]-{5,}[ \t]*\*/)'
    $script:SqlCssRegionBlankPattern = '(?m)^[ \t]*(?:--[ \t]+---[ \t]+REGION:[^\r\n]*|/\*[ \t]*REGION:[^\r\n]*)\r?\n[ \t]*\r?\n'
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.GuestSeed.psm1') -Force
    Import-Module powershell-yaml

    # The parity tests that call this read a sibling checkout itself. A
    # workspace without it has nothing to compare, and that has to fail:
    # skipped, files nobody read would count as aligned.
    function Confirm-SiblingCheckout {
        param([Parameter(Mandatory)][string]$Path)
        $Path | Should -Exist -Because "the $(Split-Path -Leaf $Path) checkout has to sit beside the framework checkout; clone it there and run this suite again"
    }

    function Resolve-ConsistencyWorkflowPath {
        param([string]$Path)
        $text = [IO.File]::ReadAllText($Path)
        if ($text.Contains('modules/New-UbuntuServerVM.ps1')) { return Join-Path (Split-Path (Split-Path $Path -Parent) -Parent) 'modules/New-UbuntuServerVM.ps1' }
        if ($text.Contains("'Stop-ExtensionService.ps1'")) { return Join-Path (Split-Path $Path -Parent) 'Stop-ExtensionService.ps1' }
        return $Path
    }

    function Get-ConsistencyWorkflowSource {
        param([string]$Path)
        return [IO.File]::ReadAllText((Resolve-ConsistencyWorkflowPath $Path))
    }

    function Get-NormalizedSource {
        param([string]$Path)
        (Get-Content -LiteralPath $Path -Raw) -replace '\r\n', "`n" -replace
            'ubuntu\.server\.(24|26)', 'ubuntu.server.VERSION'
    }

    function Get-NormalizedUbuntuSequence {
        param([string]$Path, [int]$VersionTimeout = 0, [int]$TimeoutIndent = 0, [switch]$AsObject)
        $text = Get-NormalizedSource -Path $Path
        $text = $text -replace '(?m)^sequenceGuid: .+$', 'sequenceGuid: ID'
        $text = $text -replace '(?m)^sequenceRevision: .+$', 'sequenceRevision: REVISION'
        $text = $text -replace 'Ubuntu Server (?:24|26)\.04', 'Ubuntu Server VERSION'
        $text = $text -replace 'Ubuntu (?:24|26)', 'Ubuntu VERSION'
        $text = $text -replace '(yu(?:user|website|host))(?:24|26)', '${1}VERSION'
        $text = $text -replace 'ubuntu(?:24|26)', 'ubuntuVERSION'
        if ($VersionTimeout -gt 0) {
            $indent = ' ' * $TimeoutIndent
            $text = $text -replace ('(?m)^(' + [regex]::Escape($indent) + 'timeoutSeconds: )' + $VersionTimeout + '$'), '${1}VERSION_TIMEOUT'
        }
        $document = ConvertFrom-Yaml $text -Ordered
        $structure = Copy-SequenceExecutionStructure -Node $document -SequenceRoot
        if ($AsObject) { return $structure }
        return ($structure | ConvertTo-Json -Depth 100 -Compress)
    }

    function Copy-SequenceExecutionStructure {
        param($Node, [switch]$SequenceRoot, [switch]$Step)
        if ($Node -is [Collections.IDictionary]) {
            $copy = [ordered]@{}
            foreach ($key in $Node.Keys) {
                # Descriptions belong to the sequence/step presentation layer.
                # A same-named key inside args or variables remains execution data.
                if (($SequenceRoot -or $Step) -and
                    $key -in @('description', 'descriptionLocalized')) { continue }
                $isStepList = ($SequenceRoot -and $key -in @('component', 'workload', 'steps')) -or
                    ($Step -and $key -in @('steps', 'stepsAfterVmRestart'))
                $copy[$key] = Copy-SequenceExecutionStructure -Node $Node[$key] -Step:$isStepList
            }
            return $copy
        }
        if ($Node -is [Collections.IEnumerable] -and $Node -isnot [string]) {
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Node) { $items.Add((Copy-SequenceExecutionStructure -Node $item -Step:$Step)) }
            return ,($items.ToArray())
        }
        return $Node
    }

    # --- REGION: Test-ConsistencySourcePath
    function Test-ConsistencySourcePath {
        <#
        .SYNOPSIS
            Include maintained source formats without enrolling generated runtime trees.
        #>
        param([Parameter(Mandatory)][string]$Path)
        $relative = $Path -replace '\\', '/'
        if ($relative -match '(^|/)(?:\.test-results|bin|obj|node_modules|vendor|runtime)(/|$)') { return $false }
        $leaf = [IO.Path]::GetFileName($relative)
        $extensions = @('.ps1', '.psm1', '.psd1', '.sh', '.bash', '.yml', '.yaml',
            '.user-data', '.xml', '.go', '.js', '.cjs', '.mjs', '.ts', '.tsx', '.jsx',
            '.cs', '.py', '.html', '.css', '.service', '.timer', '.cmd', '.plist',
            '.template', '.network-config', '.meta-data', '.ini', '.cfg', '.tf', '.tfvars', '.toml', '.sql')
        return [IO.Path]::GetExtension($leaf) -in $extensions -or
            $leaf -in @('Dockerfile', '.gitattributes', '.gitignore') -or
            $leaf.StartsWith('Dockerfile.', [StringComparison]::OrdinalIgnoreCase) -or
            $relative -match '(^|/)tools/githooks/[^/]+$'
    }

    function Get-ConsistencySourceFile {
        if (Get-Variable -Name ConsistencySourceFiles -Scope Script -ErrorAction SilentlyContinue) { return $script:ConsistencySourceFiles }
        $roots = @($script:RepoRoot, $script:ProjectRoot, $script:LinkRoot, $script:AmisadRoot |
            Where-Object { Test-Path -LiteralPath $_ -PathType Container })
        $script:ConsistencySourceFiles = @(foreach ($root in $roots) {
            $paths = @(& git -C $root ls-files --cached --others --exclude-standard)
            if ($LASTEXITCODE -ne 0) { throw "Could not inventory consistency sources in $root." }
            foreach ($relative in $paths | Sort-Object -Unique) {
                $path = Join-Path $root $relative
                if (-not (Test-ConsistencySourcePath -Path $relative) -or
                    -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                Get-Item -LiteralPath $path -Force
            }
        })
        return $script:ConsistencySourceFiles
    }

    function Get-ConsistencySourceText {
        param([string]$Path)
        if (-not (Get-Variable -Name ConsistencySourceText -Scope Script -ErrorAction SilentlyContinue)) { $script:ConsistencySourceText = @{} }
        if (-not $script:ConsistencySourceText.ContainsKey($Path)) { $script:ConsistencySourceText[$Path] = [IO.File]::ReadAllText($Path) }
        return $script:ConsistencySourceText[$Path]
    }

    function Get-SequenceRegionFinding {
        param([Parameter(Mandatory)][string]$Text)
        $lines = $Text -split '\r?\n'
        $allowed = @('resource', 'component', 'workload')
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]
            if ($line -match '^(?<indent>[ \t]*)# --- REGION: (?<name>[^\r\n]+)$') {
                $name = $Matches.name
                if ($Matches.indent -or $allowed -cnotcontains $name) {
                    "line $($index + 1): invalid sequence region '$name'"
                    continue
                }
                $next = $index + 1
                while ($next -lt $lines.Count -and $lines[$next] -match '^#(?! --- REGION:)(?:[ \t]|$)') { $next++ }
                if ($next -ge $lines.Count -or $lines[$next] -cnotmatch ('^' + $name + ':(?:[ \t].*)?$')) {
                    "line $($index + 1): '$name' must introduce '${name}:' without a blank line"
                }
            } elseif ($line -cmatch '^(resource|component|workload):(?:[ \t].*)?$') {
                $name = $Matches[1]
                $previous = $index - 1
                while ($previous -ge 0 -and $lines[$previous] -match '^#(?! --- REGION:)(?:[ \t]|$)') { $previous-- }
                if ($previous -lt 0 -or $lines[$previous] -cne "# --- REGION: $name") {
                    "line $($index + 1): '${name}:' requires its canonical REGION"
                }
            }
        }
    }

    function Get-StructuralRegionMatch {
        param([Parameter(Mandatory)][string]$Text, [ValidateSet('Yaml', 'Ini', 'Html', 'Xml')][string]$Kind)
        $patterns = @{
            Yaml = @'
(?m)^(?<indent>[ \t]*)# --- REGION: (?<name>[^\r\n]+)\r?\n(?:[ \t]*#(?![ \t]*---[ \t]+REGION:)[^\r\n]*\r?\n)*\k<indent>(?<key>'(?:[^'\r\n]|'')*'|"(?:[^"\\\r\n]|\\[^\r\n])*"|[A-Za-z0-9_.-]+)[ \t]*:
'@
            Ini = @'
(?m)^(?<indent>[ \t]*)# --- REGION: (?<name>[^\r\n]+)\r?\n(?:[ \t]*[#;](?![ \t]*---[ \t]+REGION:)[^\r\n]*\r?\n)*\k<indent>(?<marker>\[[A-Za-z][A-Za-z0-9_. -]*\])[ \t]*\r?$
'@
            Html = @'
(?m)^[ \t]*<!--[ \t]*REGION:[ \t]*(?<name>[^\r\n]*?)[ \t]*-->\r?\n(?:[ \t]*<!--(?![ \t]*REGION:)[^\r\n]*-->[ \t]*\r?\n)*[ \t]*<(?<marker>[A-Za-z][A-Za-z0-9:-]*)\b
'@
            Xml = @'
(?m)^[ \t]*<!--[ \t]*REGION:[ \t]*(?<name>[^\r\n]*?)[ \t]*-->\r?\n(?:[ \t]*<!--(?![ \t]*REGION:)[^\r\n]*-->[ \t]*\r?\n)*[ \t]*(?:<key>(?<marker>[^<]+)</key>|<(?<marker>[A-Za-z][A-Za-z0-9_.:-]*)\b)
'@
        }
        foreach ($match in [regex]::Matches($Text, $patterns[$Kind])) {
            $marker = $match.Groups['marker'].Value
            if ($Kind -eq 'Yaml') {
                $key = $match.Groups['key'].Value
                if ($key.StartsWith("'") -or $key.StartsWith('"')) {
                    $document = ConvertFrom-Yaml ($key + ': null') -Ordered
                    $marker = [string]@($document.Keys)[0]
                } else { $marker = $key }
            }
            [pscustomobject]@{ Name = $match.Groups['name'].Value; Marker = $marker; Match = $match }
        }
    }

    function Get-DuplicateDocumentationAnchorFinding {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
        $visible = [Collections.Generic.List[string]]::new()
        $fenceCharacter = ''
        $fenceLength = 0
        foreach ($line in $Text -split '\r?\n') {
            if ($fenceCharacter) {
                $closing = '^ {0,3}' + [regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$'
                if ($line -match $closing) { $fenceCharacter = '' }
                $visible.Add('')
                continue
            }
            $fence = [regex]::Match($line, '^ {0,3}(`{3,}|~{3,})(.*)$')
            if ($fence.Success -and -not ($fence.Groups[1].Value[0] -eq '`' -and
                    $fence.Groups[2].Value.Contains('`'))) {
                $fenceCharacter = [string]$fence.Groups[1].Value[0]
                $fenceLength = $fence.Groups[1].Length
                $visible.Add('')
                continue
            }
            $visible.Add($line)
        }
        $body = $visible -join "`n"
        # Examples and comments do not publish IDs; keep newlines for locations.
        $body = [regex]::Replace($body, '(?s)<!--.*?-->', {
            param($match)
            [regex]::Replace($match.Value, '[^\n]', ' ')
        })
        $body = [regex]::Replace($body, '(?<ticks>`+)(?!`)[^\n]*?\k<ticks>(?!`)', {
            param($match)
            ' ' * $match.Length
        })
        $htmlPattern = @'
(?i:<[a-z][a-z0-9:-]*\b(?:[^"'<>]|"[^"]*"|'[^']*')*?\s+id\s*=\s*)(?:"(?<id>[^"]+)"|'(?<id>[^']+)'|(?<id>[^\s"'=<>`]+))
'@
        $markdownPattern = '(?m)^ {0,3}#{1,6}[ \t]+[^\n]*?\{[ \t]*#(?<id>[^\s{}]+)(?:[ \t]+[^{}\n]*)?\}[ \t]*(?:#+[ \t]*)?$'
        $anchors = @(
            foreach ($match in [regex]::Matches($body, $htmlPattern)) {
                [pscustomobject]@{ Index = $match.Index; Id = [Net.WebUtility]::HtmlDecode($match.Groups['id'].Value) }
            }
            foreach ($match in [regex]::Matches($body, $markdownPattern)) {
                [pscustomobject]@{ Index = $match.Index; Id = $match.Groups['id'].Value }
            }
        )
        $firstLine = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        foreach ($anchor in $anchors | Sort-Object Index) {
            $lineNumber = 1 + [regex]::Matches($body.Substring(0, $anchor.Index), "`n").Count
            if ($firstLine.ContainsKey($anchor.Id)) {
                [pscustomobject]@{ Id = $anchor.Id; FirstLine = $firstLine[$anchor.Id]; Line = $lineNumber }
            } else { $firstLine.Add($anchor.Id, $lineNumber) }
        }
    }

    function Format-SourceMatch {
        param([IO.FileInfo]$File, [string]$Text, [Text.RegularExpressions.Match]$Match)
        $line = 1 + [regex]::Matches($Text.Substring(0, $Match.Index), "`n").Count
        $root = if ($File.FullName.StartsWith($script:ProjectRoot, [StringComparison]::Ordinal)) {
            $script:ProjectRoot
        } elseif ($File.FullName.StartsWith($script:LinkRoot, [StringComparison]::Ordinal)) {
            $script:LinkRoot
        } elseif ($File.FullName.StartsWith($script:AmisadRoot, [StringComparison]::Ordinal)) {
            $script:AmisadRoot
        } else {
            $script:RepoRoot
        }
        return "$(Split-Path -Leaf $root):$($File.FullName.Substring($root.Length + 1)):$line"
    }
}

Describe 'Ubuntu installer parity' {
    It 'keeps the shared <Workload> installer identical across Ubuntu releases' -TestCases @(
        @{ Workload = 'update' }, @{ Workload = 'code' }, @{ Workload = 'k8s' },
        @{ Workload = 'n8n' }, @{ Workload = 'openclaw' }, @{ Workload = 'postgresql' }
    ) {
        param($Workload)
        $first = Get-NormalizedSource (Join-Path $script:RepoRoot "guest/ubuntu.server.24/ubuntu.server.24.$Workload.sh")
        $second = Get-NormalizedSource (Join-Path $script:RepoRoot "guest/ubuntu.server.26/ubuntu.server.26.$Workload.sh")
        $second | Should -BeExactly $first
        $shared = Join-Path $script:RepoRoot "guest/shared/ubuntu.$Workload.sh"
        $digest = (Get-FileHash -LiteralPath $shared -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach ($release in '24', '26') {
            $entrypoint = Get-Content (Join-Path $script:RepoRoot "guest/ubuntu.server.$release/ubuntu.server.$release.$Workload.sh") -Raw
            $entrypoint | Should -Match ([regex]::Escape('workflow="guest/shared/ubuntu.' + $Workload + '.sh"'))
            $entrypoint | Should -Match ([regex]::Escape('expected="' + $digest + '"'))
        }
        if ($Workload -eq 'k8s') {
            (Get-Content $shared -Raw) | Should -Not -Match '(?m)^[ \t]*build-essential(?:[ \t\\]|$)'
        }
    }
}

Describe 'Ubuntu test-sequence parity' {
    It 'keeps the <Flow> structure aligned across Ubuntu releases' -TestCases @(
        @{ Flow = 'GUI workload'; Path24 = 'workload.guest.ubuntu.server.24.yml'; Path26 = 'workload.guest.ubuntu.server.26.yml'; Timeout24 = 1800; Timeout26 = 3000; TimeoutIndent = 4 },
        @{ Flow = 'SSH workload'; Path24 = 'workload.guest.ubuntu.server.24.ssh.yml'; Path26 = 'workload.guest.ubuntu.server.26.ssh.yml'; Timeout24 = 1800; Timeout26 = 3000; TimeoutIndent = 4 }
    ) {
        param($Flow, $Path24, $Path26, $Timeout24, $Timeout26, $TimeoutIndent)
        $null = $Flow
        $dir = Join-Path $script:RepoRoot 'test/sequences'
        # Install budgets differ by release; execution fields otherwise agree.
        $first = Get-NormalizedUbuntuSequence -Path (Join-Path $dir $Path24) -VersionTimeout $Timeout24 -TimeoutIndent $TimeoutIndent
        $second = Get-NormalizedUbuntuSequence -Path (Join-Path $dir $Path26) -VersionTimeout $Timeout26 -TimeoutIndent $TimeoutIndent
        $second | Should -BeExactly $first
    }

    It 'keeps <Flow> start steps aligned around the explicit power transition' -TestCases @(
        @{ Flow = 'GUI'; Suffix = '' },
        @{ Flow = 'SSH'; Suffix = '.ssh' }
    ) {
        param($Flow, $Suffix)
        $dir = Join-Path $script:RepoRoot 'test/sequences'
        $first = Get-NormalizedUbuntuSequence -Path (Join-Path $dir "start.guest.ubuntu.server.24$Suffix.yml") -AsObject
        $second = Get-NormalizedUbuntuSequence -Path (Join-Path $dir "start.guest.ubuntu.server.26$Suffix.yml") -AsObject
        # Ubuntu 26 alone changes processor count and needs advisory evidence
        # on both sides of that transition; preserve parity of workload steps.
        $clockSteps = @($second.workload | Where-Object action -EQ 'saveGuestClockSnapshot')
        $clockSteps.Count | Should -Be 2
        ($clockSteps.phase -join ',') | Should -BeExactly 'before-cpu-restart,after-cpu-restart'
        $beforeIndex = if ($Flow -eq 'GUI') { 2 } else { 1 }
        $second.workload[$beforeIndex].action | Should -BeExactly 'saveGuestClockSnapshot'
        $second.workload[-1].action | Should -BeExactly 'saveGuestClockSnapshot'
        $second['workload'] = @($second.workload | Where-Object action -NE 'saveGuestClockSnapshot')
        $start = [ordered]@{ action = 'startVm'; arm64HyperVProcessorCount = 2; timeoutSeconds = 180 }
        if ($Flow -eq 'GUI') {
            $second.component[0].action | Should -BeExactly 'retry'
            $second.component[0].restartVmBeforeRetry | Should -BeExactly 'arm64HyperVInstallerBoot'
            $second.component[0].maxAttempts | Should -Be 2
            $second.component[0].steps.Count | Should -Be 1
            # The boot-stall wrapper retains the same prompt and timeout on
            # every provider; only native ARM64 Hyper-V can make a second attempt.
            $second.component[0] = $second.component[0].steps[0]
            $first.component[1].steps[2].action | Should -BeExactly 'waitForTextWithNudge'
            $second.component[1].steps[2].action | Should -BeExactly 'waitForTextWithNudge'
            $first.component[1].steps[2].timeoutSeconds | Should -Be 1800
            $second.component[1].steps[2].timeoutSeconds | Should -Be 2400
            $second.component[1].steps[2]['timeoutSeconds'] = 1800
            $first.workload.Count | Should -Be 5
            $second.workload.Count | Should -Be 6
            ($first.workload[2] | ConvertTo-Json -Compress) | Should -BeExactly ([ordered]@{ action = 'inputTextAndEnter'; text = 'clear; sudo reboot now' } | ConvertTo-Json -Compress)
            ($second.workload[2] | ConvertTo-Json -Compress) | Should -BeExactly ([ordered]@{ action = 'stopVm'; timeoutSeconds = 120; forceOnTimeout = $true; frameIntervalSeconds = 30 } | ConvertTo-Json -Compress)
            ($second.workload[3] | ConvertTo-Json -Compress) | Should -BeExactly ($start | ConvertTo-Json -Compress)
            $second['workload'] = @($second.workload[0], $second.workload[1], $first.workload[2], $second.workload[4], $second.workload[5])
        } else {
            $first.workload.Count | Should -Be 2
            $second.workload.Count | Should -Be 4
            ($first.workload[1] | ConvertTo-Json -Compress) | Should -BeExactly ([ordered]@{ action = 'sshExec'; command = 'sudo reboot now && while :; do sleep 1; done'; timeoutSeconds = 60; allowFailure = $true } | ConvertTo-Json -Compress)
            ($second.workload[1] | ConvertTo-Json -Compress) | Should -BeExactly ([ordered]@{ action = 'stopVm'; timeoutSeconds = 120; forceOnTimeout = $true; frameIntervalSeconds = 30 } | ConvertTo-Json -Compress)
            ($second.workload[2] | ConvertTo-Json -Compress) | Should -BeExactly ($start | ConvertTo-Json -Compress)
            ($second.workload[3] | ConvertTo-Json -Compress) | Should -BeExactly ([ordered]@{ action = 'sshWaitReady'; timeoutSeconds = 600 } | ConvertTo-Json -Compress)
            $second['workload'] = @($second.workload[0], $first.workload[1])
        }
        ($second | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly ($first | ConvertTo-Json -Depth 100 -Compress)
    }

    It 'ignores presentation changes while retaining action and argument drift' {
        $firstPath = Join-Path $TestDrive 'first.yml'
        $secondPath = Join-Path $TestDrive 'second.yml'
        $fixture = @'
description: First wording
descriptionLocalized:
  pt-BR: First translation
component:
  - action: callExtension
    description: Step wording
    descriptionLocalized:
      pt-BR: Step translation
    method: example.Run
    args:
      action: applicationAction
      description: Execution value
      values: [null, 1]
'@
        [IO.File]::WriteAllText($firstPath, $fixture)
        [IO.File]::WriteAllText($secondPath, $fixture.Replace('First wording', 'Other wording').Replace('translation', 'localization').Replace('Step wording', 'Other step wording'))
        $expected = Get-NormalizedUbuntuSequence -Path $firstPath
        (Get-NormalizedUbuntuSequence -Path $secondPath) | Should -BeExactly $expected
        [IO.File]::WriteAllText($secondPath, $fixture.Replace('callExtension', 'waitForText'))
        (Get-NormalizedUbuntuSequence -Path $secondPath) | Should -Not -BeExactly $expected
        [IO.File]::WriteAllText($secondPath, $fixture.Replace('Execution value', 'Changed execution value'))
        (Get-NormalizedUbuntuSequence -Path $secondPath) | Should -Not -BeExactly $expected
        [IO.File]::WriteAllText($secondPath, $fixture.Replace('[null, 1]', '[1]'))
        (Get-NormalizedUbuntuSequence -Path $secondPath) | Should -Not -BeExactly $expected
    }
}

Describe 'KVM replacement ordering' {
    It 'removes the old domain before replacing files for <Guest>' -TestCases @(
        @{ Guest = 'ubuntu.server.24' }, @{ Guest = 'ubuntu.server.26' },
        @{ Guest = 'amazon.linux.2023' }, @{ Guest = 'windows.11' },
        @{ Guest = 'caching-proxy-service' }, @{ Guest = 'stash-service' },
        @{ Guest = 'pool-control-service' }, @{ Guest = 'download-agent-service' }
    ) {
        param($Guest)
        $path = Join-Path $script:RepoRoot "host/ubuntu.kvm/guest.$Guest/New-VM.ps1"
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-ConsistencyWorkflowPath $path), [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $commands = @($ast.FindAll({ param($n)
            $n -is [Management.Automation.Language.CommandAst]
        }, $true))
        $gate = @($commands | Where-Object { $_.GetCommandName() -eq 'Assert-YurunaBaseImage' })[0]
        $remove = @($commands | Where-Object { $_.GetCommandName() -eq 'Remove-KvmDomainDefinition' })[0]
        $gate | Should -Not -BeNullOrEmpty
        $remove | Should -Not -BeNullOrEmpty
        $remove.Extent.StartOffset | Should -BeGreaterThan $gate.Extent.EndOffset
        $writes = @($commands | Where-Object {
            $_.GetCommandName() -in @('Copy-Item', 'Set-Content', 'New-CloudInitUserData') -or
            $_.Extent.Text -match '^&?\s*qemu-img (create|convert|resize)\b'
        })
        $writes.Count | Should -BeGreaterThan 0
        foreach ($write in $writes) {
            $write.Extent.StartOffset | Should -BeGreaterThan $remove.Extent.EndOffset
        }
        $driver = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'))
        $driver | Should -Match "(?s)function Remove-KvmDomainDefinition.*?'destroy'.*?'undefine'.*?'list', '--all', '--name'"
        $driver | Should -Match '(?s)function Remove-KvmDomainDefinition.*?Test-DriverNativeResultComplete.*?ExitCode -ne 0.*?throw'

    }
}

Describe 'VM seed overlay contracts' {
    It 'keeps the shared globalization seed in <Service>' -TestCases @(
        @{ Service = 'stash-service' }, @{ Service = 'pool-control-service' },
        @{ Service = 'download-agent-service' }, @{ Service = 'caching-proxy-service' }
    ) {
        param($Service)
        $seed = ConvertFrom-Yaml (Get-Content (Join-Path $script:SeedRoot "$Service.base.user-data") -Raw)
        $entry = @($seed.write_files | Where-Object { $_.path -eq '/etc/yuruna/globalization.env' })
        $entry.Count | Should -Be 1
        $entry[0].owner | Should -BeExactly 'root:root'
        $entry[0].permissions | Should -BeExactly '0644'
        $entry[0].content | Should -BeExactly (
            "YURUNA_LANGUAGE=YURUNA_LANGUAGE_PLACEHOLDER`n" +
            "YURUNA_ALLOW_PSEUDO_LOCALE=YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER`n")
    }

    It 'keeps host.env key order identical across service guests' {
        $expected = $null
        foreach ($service in 'stash-service', 'pool-control-service', 'download-agent-service', 'caching-proxy-service') {
            $seed = ConvertFrom-Yaml (Get-Content (Join-Path $script:SeedRoot "$service.base.user-data") -Raw)
            $entry = @($seed.write_files | Where-Object { $_.path -eq '/etc/yuruna/host.env' })
            $entry.Count | Should -Be 1
            $text = [string]$entry[0].content
            $text = $text.Replace('YURUNA_CACHING_PROXY_SERVICE_IP=127.0.0.1',
                'YURUNA_CACHING_PROXY_SERVICE_IP=YURUNA_CACHING_PROXY_SERVICE_IP_PLACEHOLDER')
            if ($null -eq $expected) { $expected = $text }
            $text | Should -BeExactly $expected -Because "$service uses the shared host.env key order"
        }
    }

    It 'orders every overlay like its base and renders valid YAML' {
        foreach ($base in Get-ChildItem -LiteralPath $script:SeedRoot -Filter '*.base.user-data') {
            $baseKeys = @([regex]::Matches((Get-Content $base.FullName -Raw),
                '(?m)^\s*# === YURUNA_OVERLAY_([A-Z0-9_]+) ===$') | ForEach-Object { $_.Groups[1].Value })
            foreach ($platform in 'hyperv', 'kvm', 'utm') {
                $overlay = Join-Path $script:SeedRoot ($base.Name.Replace('.base.user-data', ".$platform.overlay.yml"))
                $sections = Read-OverlaySection -OverlayPath $overlay
                (@($sections.Keys) -join ',') | Should -BeExactly ($baseKeys -join ',')
                $merged = Merge-CloudInitUserData -BasePath $base.FullName -OverlayPath $overlay
                $merged | Should -Not -Match 'YURUNA_OVERLAY_'
                # Substitute the builder's real output, not a single-line stand-in: the
                # value is multi-line, and only a multi-line value exposes a token that
                # was spliced into a comment instead of its own line.
                $merged = $merged.Replace('APT_PROXY_BLOCK_PLACEHOLDER', (New-AptProxyBlock `
                            -PrimaryUri 'http://archive.ubuntu.com/ubuntu' `
                            -CachingProxyServiceUrl 'http://192.0.2.1:3128'))
                { ConvertFrom-Yaml $merged -ErrorAction Stop } | Should -Not -Throw
            }
        }
    }

    It 'never writes a substituted placeholder into a seed comment' {
        $findings = @()
        foreach ($file in Get-ChildItem -LiteralPath $script:SeedRoot -File) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($comment in [regex]::Matches($text, '(?m)^[ \t]*#[^\r\n]*$')) {
                $token = [regex]::Match($comment.Value, '\b[A-Z][A-Z0-9_]*_PLACEHOLDER\b')
                if (-not $token.Success) { continue }
                $location = Format-SourceMatch -File $file -Text $text -Match $comment
                $findings += "${location}: comment names the substituted token '$($token.Value)'"
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'placeholder substitution is substring-based, so a token named in a comment is a second injection site and a multi-line value splices into the comment'
    }

    It 'pairs each persistent KVM service channel with a running guest agent' {
        foreach ($service in 'caching-proxy-service', 'stash-service', 'pool-control-service', 'download-agent-service') {
            $base = Join-Path $script:SeedRoot "$service.base.user-data"
            $overlay = Join-Path $script:SeedRoot "$service.kvm.overlay.yml"
            $seed = ConvertFrom-Yaml (Merge-CloudInitUserData -BasePath $base -OverlayPath $overlay)
            $seed.packages | Should -Contain 'qemu-guest-agent'
            $seed.runcmd | Should -Contain 'systemctl enable qemu-guest-agent.service || true'
            $seed.runcmd | Should -Contain 'systemctl start qemu-guest-agent.service || true'
            $builder = Get-Content (Join-Path $script:RepoRoot "host/ubuntu.kvm/guest.$service/New-VM.ps1") -Raw
            $builder | Should -Match 'New-KvmServiceDomain'
            $driver = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'))
            $driver | Should -Match 'org\.qemu\.guest_agent\.0'
        }
    }

    It 'keeps the shared service-agent overlays identical for each provider' {
        foreach ($platform in 'hyperv', 'kvm', 'utm') {
            $expected = $null
            foreach ($service in 'stash-service', 'pool-control-service', 'download-agent-service') {
                $text = (Get-Content (Join-Path $script:SeedRoot "$service.$platform.overlay.yml") -Raw).Replace($service, 'SERVICE')
                if ($null -eq $expected) { $expected = $text }
                $text | Should -BeExactly $expected
            }
        }
    }

    It 'keeps shared service seed files identical after the account name is normalized' {
        $paths = @('/etc/ssh/sshd_config.d/60-yuruna-keepalive.conf', '/etc/yuruna/host.env',
            '/usr/local/lib/yuruna/yuruna-host-locate.sh', '/etc/systemd/system/yuruna-host-locate.service',
            '/etc/systemd/system/yuruna-host-locate.timer')
        foreach ($path in $paths) {
            $expected = $null
            foreach ($service in 'stash-service', 'pool-control-service', 'download-agent-service') {
                $seed = ConvertFrom-Yaml (Merge-CloudInitUserData `
                    -BasePath (Join-Path $script:SeedRoot "$service.base.user-data") `
                    -OverlayPath (Join-Path $script:SeedRoot "$service.kvm.overlay.yml"))
                $entry = @($seed.write_files | Where-Object { $_.path -eq $path })
                $entry.Count | Should -Be 1
                $text = ($entry[0] | ConvertTo-Json -Depth 6 -Compress).Replace($service, 'SERVICE')
                if ($null -eq $expected) { $expected = $text }
                $text | Should -BeExactly $expected
            }
        }
    }
}

Describe 'Project workload parity' {
    It 'keeps Helm resource blocks aligned with the documented memory exception' {
        Confirm-SiblingCheckout -Path $script:ProjectRoot
        $templates = @(
            @{ Path = 'example/website/workloads/frontend/website/templates/01-website.yml'; Memory = '256Mi' },
            @{ Path = 'example/text-to-sql/workloads/frontend/text-to-sql-ui/templates/01-text-to-sql-ui.yml'; Memory = '128Mi' }
        )
        foreach ($template in $templates) {
            $text = Get-Content -LiteralPath (Join-Path $script:ProjectRoot $template.Path) -Raw
            $text | Should -Match '(?m)^        # --- REGION: resources\r?\n        # See https://yuruna\.link/42e220c4-0009\r?\n        resources:'
            foreach ($block in 'requests', 'limits') {
                $pattern = '(?m)^          ' + $block + ':\r?\n' +
                    '            ephemeral-storage: "(?<storage>[^"]+)"\r?\n' +
                    '            memory: "(?<memory>[^"]+)"\r?\n' +
                    '            cpu: "(?<cpu>[^"]+)"'
                $match = [regex]::Match($text, $pattern)
                $match.Success | Should -BeTrue -Because "$($template.Path) defines $block in the common order"
                $expectedStorage = if ($block -eq 'requests') { '256Mi' } else { '1Gi' }
                $match.Groups['storage'].Value | Should -Be $expectedStorage
                $match.Groups['memory'].Value | Should -Be $template.Memory
                $match.Groups['cpu'].Value | Should -Be '200m'
            }
        }
    }

    It 'keeps the website Ubuntu workload copies identical' {
        Confirm-SiblingCheckout -Path $script:ProjectRoot
        $first = Get-NormalizedSource (Join-Path $script:ProjectRoot 'example/website/test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh')
        $second = Get-NormalizedSource (Join-Path $script:ProjectRoot 'example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh')
        $second | Should -BeExactly $first
    }

    It 'keeps the website <Flow> sequence aligned across Ubuntu releases' -TestCases @(
        @{ Flow = 'managed baseline'; Path24 = 'workload.guest.ubuntu.server.24.k8s.website.baseline.ssh.yml'; Path26 = 'workload.guest.ubuntu.server.26.k8s.website.baseline.ssh.yml' },
        @{ Flow = 'SSH deployment'; Path24 = 'workload.guest.ubuntu.server.24.k8s.website.ssh.yml'; Path26 = 'workload.guest.ubuntu.server.26.k8s.website.ssh.yml' },
        @{ Flow = 'warm SSH deployment'; Path24 = 'workload.guest.ubuntu.server.24.k8s.website.warm.ssh.yml'; Path26 = 'workload.guest.ubuntu.server.26.k8s.website.warm.ssh.yml' },
        @{ Flow = 'GUI deployment'; Path24 = 'workload.guest.ubuntu.server.24.k8s.website.yml'; Path26 = 'workload.guest.ubuntu.server.26.k8s.website.yml' },
        @{ Flow = 'warm plan'; Path24 = 'website.ubuntu24.warm.yml'; Path26 = 'website.ubuntu26.warm.yml' }
    ) {
        param($Flow, $Path24, $Path26)
        $null = $Flow
        Confirm-SiblingCheckout -Path $script:ProjectRoot
        $dir = Join-Path $script:ProjectRoot 'example/website/test'
        $first = Get-NormalizedUbuntuSequence -Path (Join-Path $dir $Path24)
        $second = Get-NormalizedUbuntuSequence -Path (Join-Path $dir $Path26)
        $second | Should -BeExactly $first
    }

    It 'keeps the website and text-to-sql <Family> flow aligned' -TestCases @(
        @{ Family = 'application workload'; Website = 'test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh';
            TextToSql = 'test/ubuntu.server.24/ubuntu.server.24.workload.k8s.text-to-sql.sh' },
        @{ Family = 'certificate copy'; Website = 'components/frontend/website/copy-pfx.ps1';
            TextToSql = 'components/frontend/text-to-sql-ui/copy-pfx.ps1' },
        @{ Family = 'base-image seed'; Website = 'components/frontend/website/seed-base-images.ps1';
            TextToSql = 'components/frontend/text-to-sql-ui/seed-base-images.ps1' },
        @{ Family = 'bundled build module'; Website = 'components/frontend/website/Example.Build.psm1';
            TextToSql = 'components/frontend/text-to-sql-ui/Example.Build.psm1' }
    ) {
        param($Family, $Website, $TextToSql)
        Confirm-SiblingCheckout -Path $script:ProjectRoot
        $first = Get-Content (Join-Path $script:ProjectRoot "example/website/$Website") -Raw
        $second = Get-Content (Join-Path $script:ProjectRoot "example/text-to-sql/$TextToSql") -Raw
        $first = $first.Replace('website', 'PROJECT') -replace '(?m)^\.GUID .*$', '.GUID ID'
        $second = $second.Replace('text-to-sql-ui', 'PROJECT').Replace('text-to-sql', 'PROJECT') -replace '(?m)^\.GUID .*$', '.GUID ID'
        ($second -replace '\r\n', "`n") | Should -BeExactly ($first -replace '\r\n', "`n") -Because "$Family has the same contract in both examples"
    }

    It 'ships the canonical build module in each independent example context' {
        Confirm-SiblingCheckout -Path $script:ProjectRoot
        $canonical = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'tools/Example.Build.psm1') -Raw
        foreach ($context in 'example/website/components/frontend/website', 'example/text-to-sql/components/frontend/text-to-sql-ui') {
            $bundled = Get-Content -LiteralPath (Join-Path $script:ProjectRoot "$context/Example.Build.psm1") -Raw
            ($bundled -replace '\r\n', "`n") | Should -BeExactly ($canonical -replace '\r\n', "`n")
            foreach ($wrapper in 'copy-pfx.ps1', 'seed-base-images.ps1') {
                Get-Content -LiteralPath (Join-Path $script:ProjectRoot "$context/$wrapper") -Raw |
                    Should -Match 'Join-Path \$PSScriptRoot ''Example\.Build\.psm1'''
            }
        }
    }
}

Describe 'Shared source regions' {
    It 'keeps the shared SBOM implementation identical across the three workspace projects' {
        foreach ($root in $script:ProjectRoot, $script:LinkRoot) {
            Confirm-SiblingCheckout -Path $root
            foreach ($relative in 'tools/Sync-Sbom.py', 'tools/sbom_dependencies.py', 'tools/sbom_provisioning.py') {
                $canonical = Get-FileHash -LiteralPath (Join-Path $script:RepoRoot $relative) -Algorithm SHA256
                $copy = Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256
                $copy.Hash | Should -BeExactly $canonical.Hash -Because "$relative has the same contract in all three repositories"
            }
        }
    }

    It 'keeps service image wrappers identical within each provider' {
        foreach ($hostKind in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
            $expected = $null
            foreach ($service in 'stash-service', 'pool-control-service', 'download-agent-service', 'caching-proxy-service') {
                $path = Join-Path $script:RepoRoot "host/$hostKind/guest.$service/Get-Image.ps1"
                $text = Get-ConsistencyWorkflowSource -Path $path
                $text = $text -replace '(?m)^\.GUID .+$', '.GUID ID' -replace '(?m)^\.TAGS.*$', '.TAGS'
                $text = $text -replace 'host\.operator_[0-9a-f]+', 'host.operator_KEY'
                foreach ($name in 'stash-service', 'pool-control-service', 'download-agent-service', 'caching-proxy-service') {
                    $text = $text.Replace($name, 'SERVICE')
                }
                foreach ($name in 'Stash', 'PoolControl', 'DownloadAgent', 'CachingProxy') {
                    $text = $text.Replace($name, 'SERVICE')
                }
                $text = $text -replace '\r\n', "`n"
                if ($null -eq $expected) { $expected = $text }
                $text | Should -BeExactly $expected -Because "$hostKind service image wrappers share one acquisition contract"
            }
        }
    }

    It 'keeps VM replacement phases in the common order' {
        $phases = @('Log level from environment', 'Seek the base image',
            'Remove existing VM', 'Create copies and files for VM')
        foreach ($hostKind in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
            foreach ($guest in 'stash-service', 'pool-control-service', 'download-agent-service',
                'caching-proxy-service', 'ubuntu.server.24', 'ubuntu.server.26',
                'amazon.linux.2023', 'windows.11') {
                $path = Join-Path $script:RepoRoot "host/$hostKind/guest.$guest/New-VM.ps1"
                # Indented markers count: a builder's seed-folder try/finally
                # encloses the later phases.
                $regions = @([regex]::Matches((Get-ConsistencyWorkflowSource -Path $path),
                        '(?m)^[ \t]*# --- REGION: ([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
                $observed = @($regions | Where-Object { $_ -in $phases })
                ($observed -join '|') | Should -BeExactly ($phases -join '|') -Because "$hostKind/$guest shares the replacement order"
                $source = Get-ConsistencyWorkflowSource -Path $path
                if ($hostKind -eq 'ubuntu.kvm' -and $guest -ne 'windows.11') {
                    [regex]::Matches($source, '(?m)^\$guestBinding = Resolve-GuestHostBinding\r?$').Count | Should -Be 1
                    $source | Should -Not -Match '(?m)^\$(?:networkName|YurunaHostIp|hostIp)\s*=\s*Get-(?:ExternalNetwork|BestHostIp|GuestReachableHostIp)\b'
                }
                if ($guest -eq 'amazon.linux.2023') {
                    $seedPhases = @('Yuruna harness SSH key', 'Vault user password',
                        'Yuruna host coordinates', 'Render user-data / meta-data', 'Generate cloud-init seed ISO')
                    (($regions | Where-Object { $_ -in $seedPhases }) -join '|') | Should -BeExactly ($seedPhases -join '|')
                }
            }
        }
    }

    It 'keeps each provider service builder in its shared phase order' {
        $common = @('Log level from environment', 'Seek the base image',
            'Remove existing VM', 'Create copies and files for VM',
            'Copy base image -> per-VM disk', 'Grow the per-VM disk to 256 GB',
            'Stage the cloud-init seed directory',
            'Yuruna harness SSH key', 'Vault admin password',
            'Select the guest network', 'Yuruna host coordinates', 'Generate cloud-init seed ISO',
            'Clean up temporary files')
        $providerPhases = @{
            'windows.hyper-v' = @('Create and configure the Hyper-V VM', 'Start VM and wait for IP')
            'ubuntu.kvm' = @('libvirt-qemu search ACL on $HOME',
                'Render user-data / meta-data',
                'Create and configure the libvirt domain',
                'Wait for VM IP')
            'macos.utm' = @('Create and configure the UTM bundle (config.plist, QEMU backend)',
                'Guidance', 'Restore operator file ownership')
        }
        foreach ($hostKind in 'windows.hyper-v', 'ubuntu.kvm', 'macos.utm') {
            $names = @($common + $providerPhases[$hostKind])
            $expected = $null
            foreach ($service in 'stash-service', 'pool-control-service', 'download-agent-service') {
                $path = Join-Path $script:RepoRoot "host/$hostKind/guest.$service/New-VM.ps1"
                # Indented markers count: a builder's seed-folder try/finally
                # encloses the later phases.
                $regions = @([regex]::Matches((Get-ConsistencyWorkflowSource -Path $path),
                        '(?m)^[ \t]*# --- REGION: ([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
                $observed = @($regions | Where-Object { $_ -in $names })
                if ($null -eq $expected) { $expected = $observed -join '|' }
                ($observed -join '|') | Should -BeExactly $expected -Because "$hostKind/$service shares the provider's service phases"
                $observed.Count | Should -Be $names.Count -Because "$hostKind/$service includes each shared phase once"
            }
        }
    }

    It 'starts every service lifecycle script with the common regions' {
        foreach ($verb in 'Start', 'Stop') {
            foreach ($service in 'CachingProxy', 'Stash', 'PoolControl', 'DownloadAgent') {
                $path = Join-Path $script:RepoRoot "test/service/${verb}-${service}ServiceVM.ps1"
                $text = Get-ConsistencyWorkflowSource -Path $path
                $confirm = $text.IndexOf('# --- REGION: Confirm the service operation', [StringComparison]::Ordinal)
                $runtime = $text.IndexOf('# --- REGION: Initialize service runtime', [StringComparison]::Ordinal)
                $confirm | Should -BeGreaterOrEqual 0
                $runtime | Should -BeGreaterThan $confirm
            }
        }
    }

    It 'keeps the service VM bring-up phases in the common order' {
        # Service-specific regions may sit between these; the shared phases must
        # still appear once each, in this order, in every VM-backed service.
        $phases = @('Confirm the service operation', 'Initialize service runtime',
            'Storage preflight', 'Resolve the VM builder', 'Start the host status service',
            'Verify the framework source', 'Create the VM', 'Configure Shared NAT forwarding',
            'Probe service readiness', 'Recover the VM address', 'Evaluate service readiness',
            'Publish service readiness', 'Collect failure diagnostics')
        foreach ($service in 'Stash', 'PoolControl', 'DownloadAgent') {
            $path = Join-Path $script:RepoRoot "test/service/Start-${service}ServiceVM.ps1"
            $regions = @([regex]::Matches((Get-ConsistencyWorkflowSource -Path $path),
                    '(?m)^[ \t]*# --- REGION: ([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
            $observed = @($regions | Where-Object { $_ -in $phases })
            ($observed -join '|') | Should -BeExactly ($phases -join '|') -Because "Start-${service}ServiceVM.ps1 shares the service bring-up order"
            (Get-ConsistencyWorkflowSource -Path $path) | Should -Match 'Invoke-YurunaServiceVmBuild'
            $shared = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'test/modules/Test.ServiceVm.psm1'))
            $shared | Should -Match '(?s)function Invoke-YurunaServiceVmBuild.*?Test-Path.*?Start-VM.*?Wait-VMRunning'
        }
    }

    It 'keeps service VM teardown phases in the common order' {
        $phases = @('Confirm the service operation', 'Initialize service runtime',
            'Record the stop intent', 'Clear the service marker only after stopping a verified host process',
            'Publish the service withdrawal', 'Stop the VM',
            'Remove the VM and its files', 'Verify the final VM state')
        foreach ($service in 'Stash', 'PoolControl', 'DownloadAgent') {
            $path = Join-Path $script:RepoRoot "test/service/Stop-${service}ServiceVM.ps1"
            $regions = @([regex]::Matches((Get-ConsistencyWorkflowSource -Path $path),
                    '(?m)^[ \t]*# --- REGION: ([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
            $observed = @($regions | Where-Object { $_ -in $phases })
            ($observed -join '|') | Should -BeExactly ($phases -join '|') -Because "Stop-${service}ServiceVM.ps1 shares the teardown order"
        }
    }

    It 'keeps service guest lifecycle regions in the common order' {
        $names = @('Initialize environment', 'Detect architecture', 'Load retry helpers',
            'Service user', 'Load service helpers', 'Service locale', 'Service tunables', 'Storage paths', 'Package dependencies',
            'Locate the daemon source', 'Build', 'Install the binary', 'Storage directories',
            'Environment file', 'systemd unit', 'Start the service and wait for readiness')
        foreach ($service in 'download-agent-service', 'pool-control-service', 'stash-service') {
            $path = Join-Path $script:RepoRoot "guest/ubuntu.server.26/ubuntu.server.26.$service.sh"
            $text = Get-ConsistencyWorkflowSource -Path $path
            $regions = @([regex]::Matches($text, '(?m)^# --- REGION: ([^\r\n]+)') |
                ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -in $names })
            $regions.Count | Should -Be $names.Count
            ($regions -join ',') | Should -BeExactly ($names -join ',')
        }
    }

    It 'keeps the provider contract regions in the same order' {
        $names = @('Module setup', 'Image', 'VM lifecycle', 'VM I/O', 'Discovery',
            'Networking', 'Caching-proxy service', 'Host config', 'Exports')
        $expected = $null
        foreach ($hostKind in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
            $text = Get-Content (Join-Path $script:RepoRoot "host/$hostKind/modules/Yuruna.Host.psm1") -Raw
            $regions = @([regex]::Matches($text, '(?m)^# --- REGION: ([^\r\n]+)') |
                ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -in $names })
            $regions.Count | Should -Be $names.Count
            if ($null -eq $expected) { $expected = $regions -join ',' }
            ($regions -join ',') | Should -BeExactly $expected
        }
    }

    It 'leaves no blank line immediately after a REGION marker' {
        $pattern = '(?m)^[ \t]*(?:(?:#|//)[ \t]*---[ \t]+REGION:[^\r\n]*|<!--[ \t]*(?:---[ \t]+)?REGION:[^\r\n]*-->)[ \t]*\r?\n[ \t]*\r?\n'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'a REGION marker belongs directly to the block it names'
    }

    It 'uses only canonical regions in test-sequence YAML' {
        $findings = @()
        $sequenceFiles = @(Get-ConsistencySourceFile | Where-Object {
            $_.Extension -in @('.yml', '.yaml') -and $_.FullName -match '[\\/]test[\\/]' -and
            (Get-ConsistencySourceText -Path $_.FullName) -match '(?m)^(?:sequenceGuid|sequenceRevision|resource|component|workload):'
        })
        foreach ($file in $sequenceFiles) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($finding in Get-SequenceRegionFinding -Text $text) {
                $findings += "$($file.FullName): $finding"
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'sequence regions exist only at resource, component, and workload granularity'
    }

    It 'matches YAML REGION names to the same-indent keys they precede' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.yml', '.yaml', '.user-data', '.network-config', '.meta-data')) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            $markers = Get-StructuralRegionMatch -Text $text -Kind Yaml
            foreach ($marker in $markers) {
                $name = $marker.Name
                $key = $marker.Marker
                if ($name -cne $key) {
                    $location = Format-SourceMatch -File $file -Text $text -Match $marker.Match
                    $findings += "${location}: REGION '$name' precedes '$($key):'"
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'a REGION immediately before a same-indent YAML key uses that key exact name and case'
    }

    It 'matches systemd and INI REGION names to the bracketed sections they precede' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.service', '.timer', '.ini', '.cfg', '.sh', '.user-data', '.template')) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            $markers = Get-StructuralRegionMatch -Text $text -Kind Ini
            foreach ($marker in $markers) {
                if ($marker.Name -cne $marker.Marker) {
                    $location = Format-SourceMatch -File $file -Text $text -Match $marker.Match
                    $findings += "${location}: REGION '$($marker.Name)' precedes '$($marker.Marker)'"
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'systemd and INI structural regions use the following bracketed section exact name and case'
    }

    It 'matches native HTML REGION names to the elements they precede' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -eq '.html') {
            $text = Get-ConsistencySourceText -Path $file.FullName
            $markers = Get-StructuralRegionMatch -Text $text -Kind Html
            foreach ($marker in $markers) {
                $name = $marker.Name
                $element = $marker.Marker
                if ($name -cne $element) {
                    $location = Format-SourceMatch -File $file -Text $text -Match $marker.Match
                    $findings += "${location}: REGION '$name' precedes '<$element>'"
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'native HTML structural regions use the following element exact name and case'
    }

    It 'matches XML REGION names to the elements they precede' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.xml', '.plist', '.template')) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            $markers = Get-StructuralRegionMatch -Text $text -Kind Xml
            foreach ($marker in $markers) {
                $name = $marker.Name
                $element = $marker.Marker
                if ($name -cne $element) {
                    $location = Format-SourceMatch -File $file -Text $text -Match $marker.Match
                    $findings += "${location}: REGION '$name' precedes '$element'"
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'XML structural regions use the following element exact name and case'
    }

    It 'uses stable short links rather than repository paths in REGION labels' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text,
                    '(?m)^[ \t]*(?:(?:#|//)[ \t]*---[ \t]+|<!--[ \t]*)REGION:[ \t]*(?:docs/|\.\./)[^\r\n]*')) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'a REGION rationale links to its stable yuruna.link heading'
    }

    It 'keeps documentation links as ordinary comments beside named regions' {
        $pattern = '(?m)^[ \t]*(?<comment>#|//)[ \t]*---[ \t]+REGION:[ \t]*(?:https://yuruna\.link/[^\r\n]+\r?\n[ \t]*\k<comment>[ \t]*---[ \t]+REGION:[ \t]*(?!https://)|(?!(?:https://))[^\r\n]+\r?\n[ \t]*\k<comment>[ \t]*---[ \t]+REGION:[ \t]*https://yuruna\.link/)'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'the named REGION is structural and nearby yuruna.link pointers use # See or // See'
    }

    It 'has no legacy decorative structural headers or decorative See markers' {
        $pattern = '(?m)^[ \t]*(?:(?:#|//)[ \t]*-{8,}[ \t]*|(?:#|//)[ \t]*-{2,}[ \t]+(?!REGION:|See\b)[^\r\n]*?[ \t]-{3,}[ \t]*|(?:#|//)[ \t]*---[ \t]+(?!REGION:|See\b)[A-Z][^\r\n]*|(?:#|//)[ \t]*---[ \t]+See[ \t]+https://yuruna\.link/[^\r\n]*|//[ \t]*={2,}[^\r\n]*={2,}[ \t]*|//[ \t]*[\u2500\u2501\u2550]{2,}[^\r\n]*)$'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'structural headers use the canonical REGION syntax without decorative rules'
    }

    It 'has no legacy decorative dividers in SQL or CSS sources' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.sql', '.css')) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text, $script:SqlCssDividerPattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'SQL and CSS headers use the native REGION form, not decorative -- or /* */ rules'
    }

    It 'leaves no blank line immediately after a native SQL or CSS REGION marker' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.sql', '.css')) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text, $script:SqlCssRegionBlankPattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'a native SQL or CSS REGION marker belongs directly to the block it names'
    }

    It 'uses the canonical recurring REGION vocabulary' {
        $pattern = '(?m)^[ \t]*(?:#|//)[ \t]*---[ \t]+REGION:[ \t]*(?:Install logging|Storage dirs|Cleanup temporary files|Log level from the environment)[ \t]*$'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'recurring blocks use the canonical names documented in source-consistency.md'
    }

    It 'uses native HTML REGION syntax' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -eq '.html') {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text, '(?m)^[ \t]*<!--[ \t]*---[ \t]+REGION:')) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'HTML comments use <!-- REGION: ... --> natively'
    }

    It 'keeps comment-based help inside a function when a REGION precedes it' {
        $pattern = '(?m)^[ \t]*# --- REGION:[^\r\n]+\r?\n(?:(?:[ \t]*#(?! --- REGION:)[^\r\n]*)?[ \t]*\r?\n)*[ \t]*<\#(?:(?!#>)[\s\S])*?#>[ \t]*\r?\n[ \t]*function[ \t]+'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.ps1', '.psm1')) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'help discovery requires function help before attributes and param inside the function body'
    }

    It 'keeps parameter descriptions out of metadata and on their own help lines' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.ps1', '.psm1')) {
            $text = Get-ConsistencySourceText -Path $file.FullName
            # Most files have neither form; parse only candidates to exclude
            # fixture strings without walking every function in the workspace.
            if ($text -notmatch '(?m)^[ \t]*\.PARAMETER[ \t]+\S+[ \t]+\S' -and
                $text -notmatch '(?is)<#PSScriptInfo\b(?:(?!#>)[\s\S])*?\n[ \t]*\.PARAMETER\b') { continue }
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput(
                $text, [ref]$tokens, [ref]$parseErrors)
            foreach ($token in $tokens | Where-Object Kind -EQ Comment) {
                if ($token.Text -match '(?is)^<#PSScriptInfo\b.*?\n[ \t]*\.PARAMETER\b') {
                    $findings += "$($file.FullName):$($token.Extent.StartLineNumber): parameter help inside PSScriptInfo"
                }
            }
            $helpBodies = @($ast) + @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | ForEach-Object Body)
            foreach ($body in $helpBodies) {
                $help = $body.GetHelpContent()
                if ($null -eq $help) { continue }
                foreach ($name in $help.Parameters.Keys) {
                    if ($name -match '\s') {
                        $findings += "$($file.FullName):$($body.Extent.StartLineNumber): malformed parameter help '$name'"
                    }
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'PowerShell treats the entire .PARAMETER line as the parameter name and ignores metadata as command help'
    }

    It 'discovers documented parameters in <Path>' -TestCases @(
        @{ Path = 'test/Debug-TestSequence.ps1' },
        @{ Path = 'test/Invoke-TestProject.ps1' },
        @{ Path = 'test/Start-TestRunner.ps1' },
        @{ Path = 'test/Test-CachingProxyService.ps1' },
        @{ Path = 'test/modules/Invoke-TestRunnerInnerLoop.ps1' },
        @{ Path = 'test/service/Start-CachingProxyServiceVM.ps1' },
        @{ Path = 'test/service/Start-StashServiceVM.ps1' },
        @{ Path = 'test/service/Stop-CachingProxyServiceVM.ps1' },
        @{ Path = 'test/service/Stop-StashServiceVM.ps1' }
    ) {
        param($Path)
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepoRoot $Path), [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $help = $ast.GetHelpContent()
        $help | Should -Not -BeNullOrEmpty
        $help.Parameters.Count | Should -BeGreaterThan 0
        $declared = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($name in $help.Parameters.Keys) {
            $declared | Should -Contain $name -Because 'every documented parameter must map to a callable parameter'
            $help.Parameters[$name] | Should -Not -BeNullOrEmpty
        }
    }

    It 'discovers pseudo-locale help in every service entrypoint' {
        $paths = @(foreach ($service in 'CachingProxy', 'DownloadAgent', 'PoolControl', 'Stash') {
            Join-Path $script:RepoRoot "test/service/Start-${service}ServiceVM.ps1"
        }) + @(foreach ($hostKind in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
            foreach ($service in 'caching-proxy', 'download-agent', 'pool-control', 'stash') {
                Join-Path $script:RepoRoot "host/$hostKind/guest.$service-service/New-VM.ps1"
            }
        })
        foreach ($path in $paths) {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
            $parseErrors | Should -BeNullOrEmpty
            $help = $ast.GetHelpContent()
            $help | Should -Not -BeNullOrEmpty -Because "$path needs discoverable script help"
            $help.Parameters['ALLOWPSEUDOLOCALE'] | Should -Not -BeNullOrEmpty -Because "$path documents its locale switch in command help"
        }
    }

    It 'keeps both short-link entry pages identical' {
        Confirm-SiblingCheckout -Path $script:LinkRoot
        (Get-Content (Join-Path $script:LinkRoot 'index.html') -Raw) |
            Should -BeExactly (Get-Content (Join-Path $script:LinkRoot '404.html') -Raw)
    }
}

Describe 'Consistency source inventory' {
    It 'enrolls <Path>' -TestCases @(
        @{ Path = 'tools/test_navigation.cjs' },
        @{ Path = 'tools/test_navigation.test.cjs' },
        @{ Path = 'src/module.mjs' },
        @{ Path = 'src/component.tsx' },
        @{ Path = 'src/component.jsx' },
        @{ Path = 'src/config.ts' },
        @{ Path = 'globalization/generated/powershell/en-US.psd1' },
        @{ Path = 'test/status/yuruna.common.css' },
        @{ Path = 'example/text-to-sql/db/schema.sql' },
        @{ Path = 'db/migrations/001-init.sql' },
        @{ Path = 'components/site/Dockerfile' },
        @{ Path = 'components/site/Dockerfile.debug' },
        @{ Path = 'tools/githooks/pre-commit' },
        @{ Path = 'tools\githooks\pre-push' },
        @{ Path = '.gitattributes' },
        @{ Path = '.gitignore' },
        @{ Path = 'global/resources/localhost/registry/localhost-registry.tf' },
        @{ Path = 'config/environment.tfvars' },
        @{ Path = 'config/settings.toml' },
        @{ Path = 'test/runtime.ps1' },
        @{ Path = 'test/binocular.ps1' }
    ) {
        param($Path)
        Test-ConsistencySourcePath -Path $Path | Should -BeTrue
    }

    It 'excludes <Path>' -TestCases @(
        @{ Path = 'docs/source-consistency.md' },
        @{ Path = 'fixtures/source.patch' },
        @{ Path = 'assets/image.png' },
        @{ Path = 'node_modules/example/script.cjs' },
        @{ Path = 'src/vendor/script.mjs' },
        @{ Path = 'src/bin/module.ps1' },
        @{ Path = 'src/obj/module.ps1' },
        @{ Path = 'test/status/runtime/generated.ps1' },
        @{ Path = '.test-results/generated.ps1' },
        @{ Path = '.test-results/generated.sql' },
        @{ Path = 'test\status\runtime\generated.ps1' }
    ) {
        param($Path)
        Test-ConsistencySourcePath -Path $Path | Should -BeFalse
    }

    It 'audits the maintained CommonJS, Dockerfile and Git hook blocks' {
        $paths = @(Get-ConsistencySourceFile | ForEach-Object FullName)
        $paths | Should -Contain (Join-Path $script:RepoRoot '.gitattributes')
        foreach ($relative in 'tools/test_navigation.cjs', 'tools/test_navigation.test.cjs',
            'example/website/components/frontend/website/Dockerfile', 'tools/githooks/pre-commit') {
            $paths | Should -Contain (Join-Path $script:ProjectRoot $relative)
        }
    }
}

Describe 'SQL and CSS divider fixtures' {
    It 'flags <Name>' -ForEach @(
        @{ Name = 'a SQL legacy title'; Text = '-- -- Reference tables -----' },
        @{ Name = 'a SQL rule line'; Text = '-- ---------------------------------------------' },
        @{ Name = 'a SQL title with a trailing rule'; Text = '-- Core entities ------------------------' },
        @{ Name = 'a CSS legacy title'; Text = '/* -- Page header -------------------------------------------------------- */' },
        @{ Name = 'a CSS rule opener'; Text = '/* --------------------------------------------------------------------------' },
        @{ Name = 'a CSS trailing rule'; Text = '/* ---------- header chrome (both windows) ---------- */' }
    ) {
        param($Name, $Text)
        $null = $Name
        [regex]::IsMatch($Text, $script:SqlCssDividerPattern) | Should -BeTrue
    }

    It 'leaves <Name> alone' -ForEach @(
        @{ Name = 'a SQL native region'; Text = '-- --- REGION: Reference tables' },
        @{ Name = 'a SQL prose comment'; Text = '-- Yuruna Text-to-SQL example schema: a small SaaS-style' },
        @{ Name = 'a CSS native region'; Text = '/* REGION: Page header */' },
        @{ Name = 'a CSS custom property in prose'; Text = '/* --fg-header is white and stays white here, in both color schemes */' }
    ) {
        param($Name, $Text)
        $null = $Name
        [regex]::IsMatch($Text, $script:SqlCssDividerPattern) | Should -BeFalse
    }

    It 'flags a blank line after <Name>' -ForEach @(
        @{ Name = 'a SQL region'; Text = "-- --- REGION: Seed data`n`nINSERT INTO geography VALUES (1);" },
        @{ Name = 'a CSS region'; Text = "/* REGION: Page header */`r`n`r`n.page-header { color: red; }" }
    ) {
        param($Name, $Text)
        $null = $Name
        [regex]::IsMatch($Text, $script:SqlCssRegionBlankPattern) | Should -BeTrue
    }

    It 'accepts a region directly followed by content for <Name>' -ForEach @(
        @{ Name = 'a SQL region'; Text = "-- --- REGION: Seed data`nINSERT INTO geography VALUES (1);" },
        @{ Name = 'a CSS region'; Text = "/* REGION: Page header */`n.page-header { color: red; }" }
    ) {
        param($Name, $Text)
        $null = $Name
        [regex]::IsMatch($Text, $script:SqlCssRegionBlankPattern) | Should -BeFalse
    }
}

Describe 'Sequence region guard fixtures' {
    It 'accepts <Name>' -TestCases @(
        @{ Name = 'a resource region'; Text = "# --- REGION: resource`nresource: {}" },
        @{ Name = 'ordinary documentation beside a component region'; Text = "# --- REGION: component`n# See https://yuruna.link/42e220c4-0011`n# Console readiness.`ncomponent: []" },
        @{ Name = 'CRLF and a workload region'; Text = "# --- REGION: workload`r`nworkload: []`r`n" }
    ) {
        param($Name, $Text)
        $null = $Name
        @(Get-SequenceRegionFinding -Text $Text) | Should -BeNullOrEmpty
    }

    It 'rejects <Name>' -TestCases @(
        @{ Name = 'an unmarked resource'; Text = 'resource: {}' },
        @{ Name = 'an unmarked component'; Text = 'component: []' },
        @{ Name = 'an unmarked workload'; Text = 'workload: []' },
        @{ Name = 'different marker case'; Text = "# --- REGION: Resource`nresource: {}" },
        @{ Name = 'a variable region'; Text = "# --- REGION: variables`nvariables: {}" },
        @{ Name = 'an action region'; Text = "# --- REGION: action`n- action: waitForText" },
        @{ Name = 'a nested component region'; Text = "  # --- REGION: component`n  component: []" },
        @{ Name = 'a documentation link as a structural region'; Text = "# --- REGION: https://yuruna.link/42e220c4-0011`ncomponent: []" },
        @{ Name = 'a blank line after the region'; Text = "# --- REGION: component`n`ncomponent: []" },
        @{ Name = 'a blank line after its documentation'; Text = "# --- REGION: component`n# See https://yuruna.link/42e220c4-0011`n`ncomponent: []" },
        @{ Name = 'a region introducing the wrong key'; Text = "# --- REGION: resource`ncomponent: []" },
        @{ Name = 'a region without a block'; Text = '# --- REGION: workload' }
    ) {
        param($Name, $Text)
        $null = $Name
        @(Get-SequenceRegionFinding -Text $Text).Count | Should -BeGreaterThan 0
    }
}

Describe 'Structural region guard fixtures' {
    It 'compares the exact marker across ordinary comments for <Name>' -TestCases @(
        @{ Name = 'YAML quoted key'; Kind = 'Yaml'; Region = 'network'; Marker = 'network'; Text = "# --- REGION: network`n# Inline constraint`n# See https://yuruna.link/42e220c4-0006`n'network' : {}" },
        @{ Name = 'YAML indented comment'; Kind = 'Yaml'; Region = 'Wrong'; Marker = 'network'; Text = "# --- REGION: Wrong`n  # Inline constraint`nnetwork: {}" },
        @{ Name = 'YAML quoted spaces and colon'; Kind = 'Yaml'; Region = 'network settings: local'; Marker = 'network settings: local'; Text = "# --- REGION: network settings: local`n  # Inline constraint`n'network settings: local': {}" },
        @{ Name = 'YAML escaped single quote'; Kind = 'Yaml'; Region = "user's settings"; Marker = "user's settings"; Text = "# --- REGION: user's settings`n'user''s settings': {}" },
        @{ Name = 'YAML escaped double quote'; Kind = 'Yaml'; Region = 'network "settings"'; Marker = 'network "settings"'; Text = ('# --- REGION: network "settings"' + "`n" + '"network \"settings\"": {}') },
        @{ Name = 'INI indented comment'; Kind = 'Ini'; Region = '[service]'; Marker = '[Service]'; Text = "# --- REGION: [service]`n  ; Inline constraint`n[Service]" },
        @{ Name = 'YAML case mismatch'; Kind = 'Yaml'; Region = 'Network'; Marker = 'network'; Text = "# --- REGION: Network`n# Inline constraint`nnetwork: {}" },
        @{ Name = 'YAML nested quoted key with CRLF'; Kind = 'Yaml'; Region = 'Network'; Marker = 'network'; Text = "  # --- REGION: Network`r`n  # Inline constraint`r`n  `"network`": {}" },
        @{ Name = 'INI semicolon comment'; Kind = 'Ini'; Region = '[service]'; Marker = '[Service]'; Text = "# --- REGION: [service]`n; Inline constraint`n[Service]" },
        @{ Name = 'INI hash comment'; Kind = 'Ini'; Region = '[Service]'; Marker = '[Service]'; Text = "# --- REGION: [Service]`n# Inline constraint`n[Service]" },
        @{ Name = 'HTML ordinary comment'; Kind = 'Html'; Region = 'Main'; Marker = 'main'; Text = "<!-- REGION: Main -->`n<!-- Inline constraint -->`n<main>" },
        @{ Name = 'HTML link and CRLF'; Kind = 'Html'; Region = 'main'; Marker = 'main'; Text = "<!-- REGION: main -->`r`n<!-- See https://yuruna.link/42e220c4-000a -->`r`n<main>" },
        @{ Name = 'plist key comment'; Kind = 'Xml'; Region = 'Name'; Marker = 'name'; Text = "<!-- REGION: Name -->`n<!-- Inline constraint -->`n<key>name</key>" },
        @{ Name = 'XML element comment'; Kind = 'Xml'; Region = 'settings'; Marker = 'settings'; Text = "<!-- REGION: settings -->`n<!-- Inline constraint -->`n<settings>" }
    ) {
        param($Kind, $Region, $Marker, $Text)
        $regionMatches = @(Get-StructuralRegionMatch -Text $Text -Kind $Kind)
        $regionMatches.Count | Should -Be 1
        $regionMatches[0].Name | Should -BeExactly $Region
        $regionMatches[0].Marker | Should -BeExactly $Marker
        ($regionMatches[0].Name -cne $regionMatches[0].Marker) | Should -Be ($Region -cne $Marker)
    }

    It 'does not bridge another block for <Name>' -TestCases @(
        @{ Name = 'YAML blank line'; Kind = 'Yaml'; ExpectedCount = 0; Text = "# --- REGION: Outer`n`nnetwork: {}" },
        @{ Name = 'YAML changed indentation'; Kind = 'Yaml'; ExpectedCount = 0; Text = "# --- REGION: Outer`n  network: {}" },
        @{ Name = 'YAML second region'; Kind = 'Yaml'; ExpectedCount = 1; Text = "# --- REGION: Outer`n# --- REGION: network`nnetwork: {}" },
        @{ Name = 'INI blank line'; Kind = 'Ini'; ExpectedCount = 0; Text = "# --- REGION: Outer`n`n[Service]" },
        @{ Name = 'INI second region'; Kind = 'Ini'; ExpectedCount = 1; Text = "# --- REGION: Outer`n# --- REGION: [Service]`n[Service]" },
        @{ Name = 'HTML blank line'; Kind = 'Html'; ExpectedCount = 0; Text = "<!-- REGION: Outer -->`n`n<main>" },
        @{ Name = 'HTML second region'; Kind = 'Html'; ExpectedCount = 1; Text = "<!-- REGION: Outer -->`n<!-- REGION: main -->`n<main>" },
        @{ Name = 'XML blank line'; Kind = 'Xml'; ExpectedCount = 0; Text = "<!-- REGION: Outer -->`n`n<key>Name</key>" },
        @{ Name = 'XML second region'; Kind = 'Xml'; ExpectedCount = 1; Text = "<!-- REGION: Outer -->`n<!-- REGION: Name -->`n<key>Name</key>" }
    ) {
        param($Kind, $Text, $ExpectedCount)
        $regionMatches = @(Get-StructuralRegionMatch -Text $Text -Kind $Kind)
        $regionMatches.Count | Should -Be $ExpectedCount
        foreach ($match in $regionMatches) {
            $match.Name | Should -Not -BeExactly 'Outer'
        }
    }
}

Describe 'Stable documentation anchors beside legacy aliases' {
    BeforeAll {
        $path = Join-Path $script:RepoRoot 'tools/Invoke-DocAnchor.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-ConsistencyWorkflowPath $path), [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Get-ExistingAnchor'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $script:AnchorPattern = '^<a id="(42[0-9a-f]{6})-([0-9a-f]{4})"></a>$'
    }

    It 'preserves the original id when a legacy alias precedes a heading' {
        $lines = @('<a id="42abcdef-0003"></a>', '', '<a id="old-heading"></a>', '', '## Current heading')
        $found = Get-ExistingAnchor -Line $lines -HeadingIndex 4
        $found.File | Should -Be '42abcdef'
        $found.Anchor | Should -Be '0003'
        $found.Index | Should -Be 0
    }

    It 'does not take an id across intervening document content' {
        $lines = @('<a id="42abcdef-0003"></a>', 'A paragraph.', '', '## New heading')
        Get-ExistingAnchor -Line $lines -HeadingIndex 3 | Should -BeNullOrEmpty
    }

    It 'preserves a title anchor below the first H1 with <Layout>' -TestCases @(
        @{ Layout = 'no blank lines'; Lines = @('# Title', '<a id="42abcdef-0001"></a>', 'Purpose.'); Index = 1 },
        @{ Layout = 'blank lines'; Lines = @('# Title', '', '<a id="42abcdef-0001"></a>', '', 'Purpose.'); Index = 2 },
        @{ Layout = 'a legacy title alias'; Lines = @('# Title', '', '<a id="42abcdef-0001"></a>', '<a id="old-title"></a>', '', 'Purpose.'); Index = 2 },
        @{ Layout = 'no introductory text'; Lines = @('# Title', '', '<a id="42abcdef-0001"></a>'); Index = 2 }
    ) {
        param($Lines, $Index)
        $found = Get-ExistingAnchor -Line $Lines -HeadingIndex 0
        $found.File | Should -BeExactly '42abcdef'
        $found.Anchor | Should -BeExactly '0001'
        $found.Index | Should -Be $Index
    }

    It 'does not borrow a following anchor for <Layout>' -TestCases @(
        @{ Layout = 'a subsection'; Lines = @('## Title', '', '<a id="42abcdef-0001"></a>', '', 'Purpose.'); HeadingIndex = 0 },
        @{ Layout = 'a later H1'; Lines = @('Introduction.', '# Title', '', '<a id="42abcdef-0001"></a>', '', 'Purpose.'); HeadingIndex = 1 },
        @{ Layout = 'intervening prose'; Lines = @('# Title', '', 'Purpose.', '', '<a id="42abcdef-0001"></a>'); HeadingIndex = 0 },
        @{ Layout = 'the next section'; Lines = @('# Title', '', '<a id="42abcdef-0002"></a>', '', '## Section'); HeadingIndex = 0 },
        @{ Layout = 'the next section with a legacy alias'; Lines = @('# Title', '', '<a id="42abcdef-0002"></a>', '<a id="old-section"></a>', '', '## Section'); HeadingIndex = 0 }
    ) {
        param($Lines, $HeadingIndex)
        Get-ExistingAnchor -Line $Lines -HeadingIndex $HeadingIndex | Should -BeNullOrEmpty
    }
}

Describe 'Explicit documentation anchor uniqueness' {
    It 'keeps IDs unique within each enrolled Markdown document' {
        $roots = @{ yuruna = $script:RepoRoot; 'yuruna-project' = $script:ProjectRoot; 'yuruna.link' = $script:LinkRoot }
        $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $registry = Get-Content (Join-Path $script:RepoRoot 'globalization/manifests/doc-anchors.json') -Raw | ConvertFrom-Json
        foreach ($document in $registry.files | Where-Object { $roots.ContainsKey($_.repo) }) {
            $null = $paths.Add((Join-Path $roots[$document.repo] $document.source))
            foreach ($translation in $document.translations.PSObject.Properties) {
                $null = $paths.Add((Join-Path $roots[$document.repo] ([string]$translation.Value)))
            }
        }
        $translations = Get-Content (Join-Path $script:RepoRoot 'globalization/manifests/doc-translations.json') -Raw | ConvertFrom-Json
        foreach ($document in $translations.documents | Where-Object { $roots.ContainsKey($_.repo) }) {
            $null = $paths.Add((Join-Path $roots[$document.repo] $document.source))
            $null = $paths.Add((Join-Path $roots[$document.repo] $document.translated))
        }
        $null = $paths.Add((Join-Path $script:RepoRoot 'docs/source-consistency.md'))
        $null = $paths.Add((Join-Path $script:LinkRoot 'README.md'))
        $findings = @()
        foreach ($path in $paths | Sort-Object) {
            $path | Should -Exist
            foreach ($finding in Get-DuplicateDocumentationAnchorFinding -Text ([IO.File]::ReadAllText($path))) {
                $findings += "${path}:$($finding.Line): duplicate id '$($finding.Id)' (first at line $($finding.FirstLine))"
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'an explicit ID identifies exactly one location inside a document'
    }

    It 'accepts <Name>' -TestCases @(
        @{ Name = 'distinct stable and legacy aliases'; Text = "<a id=`"42abcdef-0003`"></a>`n<a id=`"old-heading`"></a>`n## Heading" },
        @{ Name = 'case-distinct HTML IDs'; Text = '<a id="Topic"></a><a id="topic"></a>' },
        @{ Name = 'backtick fenced examples'; Text = '<a id="topic"></a>' + "`n" + '```html' + "`n" + '<a id="topic"></a>' + "`n" + '```' },
        @{ Name = 'a longer tilde fence with a shorter interior fence'; Text = "~~~~html`n<a id=`"topic`"></a>`n~~~`n<a id=`"topic`"></a>`n~~~~`n<a id=`"topic`"></a>" },
        @{ Name = 'inline code examples'; Text = '`<a id="topic"></a>` and `<a id="topic"></a>`' },
        @{ Name = 'HTML comments'; Text = "<!--`n<a id=`"topic`"></a>`n<a id=`"topic`"></a>`n-->`n<a id=`"topic`"></a>" },
        @{ Name = 'ID-like text inside other attributes'; Text = '<a title=''id="topic"'' id="first"></a><div title=''id="topic"'' id="second"></div>' },
        @{ Name = 'data-id attributes'; Text = '<div data-id="topic"></div><div data-id="topic"></div>' },
        @{ Name = 'an empty document'; Text = '' }
    ) {
        param($Name, $Text)
        $null = $Name
        @(Get-DuplicateDocumentationAnchorFinding -Text $Text) | Should -BeNullOrEmpty
    }

    It 'rejects <Name> and reports both locations' -TestCases @(
        @{ Name = 'repeated stable IDs on separate headings'; Text = "<a id=`"topic`"></a>`n## First`n<a id=`"topic`"></a>`n## Second"; Id = 'topic'; First = 1; Repeat = 3 },
        @{ Name = 'repeated heading-adjacent IDs'; Text = "<a id=`"42abcdef-0003`"></a>`n`n<a id=`"42abcdef-0003`"></a>`n`n## Heading"; Id = '42abcdef-0003'; First = 1; Repeat = 3 },
        @{ Name = 'repeated legacy aliases'; Text = "<a id=`"old-heading`"></a>`n<a id=`"old-heading`"></a>"; Id = 'old-heading'; First = 1; Repeat = 2 },
        @{ Name = 'mixed HTML tag, attribute case and quoting'; Text = "<a ID='topic'></a>`n<div id=topic></div>"; Id = 'topic'; First = 1; Repeat = 2 },
        @{ Name = 'repeated explicit Markdown heading IDs'; Text = "## First {#topic}`n## Second {#topic}"; Id = 'topic'; First = 1; Repeat = 2 },
        @{ Name = 'a Markdown ID repeated by HTML'; Text = "## First {#topic}`n<a id=`"topic`"></a>"; Id = 'topic'; First = 1; Repeat = 2 },
        @{ Name = 'equivalent HTML entity IDs'; Text = "<a id='topic&#45;one'></a>`n<div id=topic-one></div>"; Id = 'topic-one'; First = 1; Repeat = 2 },
        @{ Name = 'CRLF locations'; Text = "<a id=`"topic`"></a>`r`nA paragraph.`r`n<a id=`"topic`"></a>"; Id = 'topic'; First = 1; Repeat = 3 }
    ) {
        param($Name, $Text, $Id, $First, $Repeat)
        $null = $Name
        $found = @(Get-DuplicateDocumentationAnchorFinding -Text $Text)
        $found.Count | Should -Be 1
        $found[0].Id | Should -BeExactly $Id
        $found[0].FirstLine | Should -Be $First
        $found[0].Line | Should -Be $Repeat
    }

    It 'allows separate documents to reuse an ID without retaining prior state' {
        $text = '<a id="42abcdef-0003"></a>'
        @(Get-DuplicateDocumentationAnchorFinding -Text $text) | Should -BeNullOrEmpty
        @(Get-DuplicateDocumentationAnchorFinding -Text $text) | Should -BeNullOrEmpty
    }
}
