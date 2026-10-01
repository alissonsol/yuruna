<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42cf4f7f-3c33-488c-8cc6-1cb70b8f8836
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test git hook pre-commit pester
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
    Run the real commit hook in synthetic repositories whose tools are stubs,
    and hold it to the order of its passes and to what each one may block.
.DESCRIPTION
    The hook is the one gate every commit meets, and it runs from the working
    tree, so a broken edit to it aborts the very commit that carries it. Each
    case builds a repository under TestDrive with a byte copy of the hook and
    stub tools that record how they were called; the stubs answer the way the
    real tools do on the paths the hook reads.

    Run: Invoke-Pester -Path test/modules/Test.PreCommitHook.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Hook = Join-Path $script:RepoRoot 'tools/githooks/pre-commit'
$script:SavedEnvironment = @{}
foreach ($name in 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'YURUNA_TRANSLATE', 'YURUNA_HOOK_TEST_LOG') {
    $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
# The user's global git configuration (signing, hooks, autocrlf) must not
# reach the fixture repositories.
$script:EmptyGitConfig = Join-Path $TestDrive 'empty-gitconfig'
[IO.File]::WriteAllText($script:EmptyGitConfig, '')
$env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:YURUNA_TRANSLATE = $null
# The drafter is private; its path is assembled so this public file never
# names it as one string.
$script:DrafterRelative = 'dev-only' + '/' + 'New-Translation.ps1'

function Write-FixtureFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside TestDrive.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Executable)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
    if ($Executable -and -not $IsWindows) { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]493) }
}

function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Argument)
    $output = & git -C $Repository -c commit.gpgsign=false -c core.autocrlf=false @Argument 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Argument -join ' ') failed in ${Repository}: $output" }
    return @($output | ForEach-Object { [string]$_ })
}

# A stub records its name and arguments, then does what its behavior says.
function Get-StubText {
    param([Parameter(Mandatory)][string]$Name, [string]$Behavior = 'exit 0')
    return @"
`$record = [ordered]@{ tool = '$Name'; args = @(`$args | ForEach-Object { [string]`$_ }) }
[IO.File]::AppendAllText(`$env:YURUNA_HOOK_TEST_LOG, (ConvertTo-Json -InputObject `$record -Compress) + "``n")
`$root = Split-Path -Parent (Split-Path -Parent `$PSCommandPath)
`$base = Split-Path -Parent `$root
$Behavior
"@
}

function New-HookRepository {
    <#
    .SYNOPSIS
        A committed repository with the real hook, stub tools and a clean
        project checkout beside it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates disposable repositories under TestDrive.')]
    param([Parameter(Mandatory)][string]$Name, [string]$Drafter, [switch]$PrivateRunner)
    $base = Join-Path $TestDrive $Name
    $root = Join-Path $base 'yuruna'
    $project = Join-Path $base 'yuruna-project'
    [void][IO.Directory]::CreateDirectory($root)
    $hook = Join-Path $root 'tools/githooks/pre-commit'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $hook))
    [IO.File]::Copy($script:Hook, $hook)
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($hook, [IO.UnixFileMode]493) }
    foreach ($tool in 'Test-AsciiNoBom', 'Invoke-CatalogEmbed', 'Test-SuiteBaseline') {
        Write-FixtureFile -Path (Join-Path $root "tools/$tool.ps1") -Text (Get-StubText -Name $tool)
    }
    # The compiler exits 1 when it wrote, so the hook reads success from the
    # summary line; a file beside the repository replaces what it prints.
    Write-FixtureFile -Path (Join-Path $root 'tools/Invoke-CatalogCompile.ps1') -Text (Get-StubText -Name 'Invoke-CatalogCompile' -Behavior @'
$scripted = Join-Path $base 'compile-output.txt'
if ([IO.File]::Exists($scripted)) { [IO.File]::ReadAllText($scripted).TrimEnd("`n") -split "`n" | ForEach-Object { Write-Output $_ }; exit 1 }
$writes = Join-Path $base 'compile-writes.txt'
$count = 0
if ([IO.File]::Exists($writes)) {
    foreach ($relative in [IO.File]::ReadAllLines($writes)) {
        $path = Join-Path $root $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, "generated`n")
        Write-Output "WROTE  $relative"
        $count++
    }
}
Write-Output "PASS; wrote $count artifact(s)."
exit 1
'@)
    Write-FixtureFile -Path (Join-Path $root 'tools/Invoke-DomainInventory.ps1') -Text (Get-StubText -Name 'Invoke-DomainInventory' -Behavior @'
$stale = Join-Path $base 'inventory-stale'
if ($args -contains '-Update') {
    $path = Join-Path $root 'globalization/manifests/domain-inventory.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path, "{ `"regenerated`": true }`n")
    if ([IO.File]::Exists($stale)) { [IO.File]::Delete($stale) }
    exit 0
}
if ([IO.File]::Exists($stale)) { Write-Output 'census: STALE'; exit 1 }
exit 0
'@)
    if ($Drafter) { Write-FixtureFile -Path (Join-Path $root $script:DrafterRelative) -Text (Get-StubText -Name 'New-Translation' -Behavior $Drafter) }
    if ($PrivateRunner) { Write-FixtureFile -Path (Join-Path $root 'dev-only/tools/Invoke-DevOnlyTests.ps1') -Text (Get-StubText -Name 'Invoke-DevOnlyTests') }
    Write-FixtureFile -Path (Join-Path $root 'globalization/catalogs/en-US/demo.json') -Text "{ `"schema`": `"yuruna.catalog/v1`", `"domain`": `"demo`", `"locale`": `"en-US`", `"messages`": {} }`n"
    Write-FixtureFile -Path (Join-Path $root 'README.md') -Text "# Fixture`n"
    Write-FixtureFile -Path (Join-Path $project 'README.md') -Text "# Project fixture`n"
    foreach ($repository in $root, $project) {
        $null = Invoke-FixtureGit -Repository $repository -Argument @('init', '--initial-branch=main', '--quiet')
        foreach ($setting in @(@('user.name', 'Synthetic test'), @('user.email', 'fixture@example.invalid'), @('commit.gpgsign', 'false'))) {
            $null = Invoke-FixtureGit -Repository $repository -Argument (@('config') + $setting)
        }
        $null = Invoke-FixtureGit -Repository $repository -Argument @('add', '-A')
        $null = Invoke-FixtureGit -Repository $repository -Argument @('-c', 'core.hooksPath=', 'commit', '-q', '-m', 'seed')
    }
    $null = Invoke-FixtureGit -Repository $root -Argument @('config', 'core.hooksPath', 'tools/githooks')
    return @{ Base = $base; Root = $root; Project = $project; Log = (Join-Path $base 'tool-calls.jsonl') }
}

function Set-EnglishCatalog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Edits only a fixture repository under TestDrive.')]
    param([Parameter(Mandatory)][hashtable]$Fixture, [string]$Key = 'demo.fresh')
    Write-FixtureFile -Path (Join-Path $Fixture.Root 'globalization/catalogs/en-US/demo.json') -Text ("{ `"schema`": `"yuruna.catalog/v1`", `"domain`": `"demo`", `"locale`": `"en-US`", `"messages`": { `"$Key`": { `"message`": `"Fresh text`", `"description`": `"A fixture message.`", `"lifecycle`": `"active`" } } }`n")
    $null = Invoke-FixtureGit -Repository $Fixture.Root -Argument @('add', '--', 'globalization/catalogs/en-US/demo.json')
}

function Invoke-HookCommit {
    <#
    .SYNOPSIS
        Commit in the fixture as a person would, and read what the stubs recorded.
    #>
    param([Parameter(Mandatory)][hashtable]$Fixture, [string[]]$Path = @(), [hashtable]$Environment = @{}, [string[]]$Option = @())
    if ([IO.File]::Exists($Fixture.Log)) { [IO.File]::Delete($Fixture.Log) }
    $env:YURUNA_HOOK_TEST_LOG = $Fixture.Log
    $saved = @{}
    foreach ($name in $Environment.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); if ($null -eq $Environment[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "Env:$name" -Value $Environment[$name] } }
    try {
        $arguments = @('-C', $Fixture.Root, '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'fixture change') + $Option
        if ($Path.Count) { $arguments += @('--') + $Path }
        $output = & git @arguments 2>&1 | ForEach-Object { [string]$_ }
        $code = $LASTEXITCODE
    } finally {
        foreach ($name in $saved.Keys) { if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] } }
    }
    $calls = if ([IO.File]::Exists($Fixture.Log)) { @([IO.File]::ReadAllLines($Fixture.Log) | Where-Object { $_ } | ForEach-Object { ConvertFrom-Json -InputObject $_ }) } else { @() }
    return @{ Code = $code; Text = (@($output) -join "`n"); Calls = $calls; Tools = @($calls | ForEach-Object { $_.tool }) }
}

function Get-HeadName {
    param([Parameter(Mandatory)][hashtable]$Fixture)
    return @(Invoke-FixtureGit -Repository $Fixture.Root -Argument @('ls-tree', '-r', '--name-only', 'HEAD'))
}
}

AfterAll {
    foreach ($name in $script:SavedEnvironment.Keys) { if ($null -eq $script:SavedEnvironment[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "Env:$name" -Value $script:SavedEnvironment[$name] } }
}

Describe 'the commit hook' {

    It 'still runs every later pass when dev-only is absent' {
        $fixture = New-HookRepository -Name 'public-mirror'
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $order = @($run.Tools | Where-Object { $_ -in 'Invoke-CatalogCompile', 'Invoke-CatalogEmbed', 'Invoke-DomainInventory' })
        $order | Should -Be @('Invoke-CatalogCompile', 'Invoke-CatalogEmbed', 'Invoke-DomainInventory')
        $run.Text | Should -Not -Match 'New-Translation'
        $run.Tools | Should -Not -Contain 'New-Translation'
    }

    It 'does not start the drafter when no English catalog is staged' {
        $fixture = New-HookRepository -Name 'no-english' -Drafter 'exit 0'
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'README.md')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Tools | Should -Not -Contain 'New-Translation'
        $run.Tools | Should -Not -Contain 'Invoke-CatalogCompile'
        $run.Tools | Should -Not -Contain 'Invoke-CatalogEmbed'
        $run.Tools | Should -Contain 'Invoke-DomainInventory'
    }

    It 'runs both catalog generators for staged sources, generators, and generated destinations' {
        $cases = @(
            @{ Name = 'kernel'; Path = 'globalization/kernel/yuruna.i18n.js' }
            @{ Name = 'generator'; Path = 'tools/Invoke-CatalogEmbed.ps1' }
            @{ Name = 'compiled'; Path = 'globalization/generated/browser/en-US.demo.js' }
            @{ Name = 'runtime'; Path = 'test/status/pt-BR.status.js' }
            @{ Name = 'go-runtime'; Path = 'test/extension/pool-control-service/server/internal/catalog/enUS_status.go' }
        )
        foreach ($case in $cases) {
            $fixture = New-HookRepository -Name "catalog-$($case.Name)"
            $path = Join-Path $fixture.Root $case.Path
            $existing = if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path) } else { '' }
            $comment = if ($case.Path.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) { '#' } else { '//' }
            Write-FixtureFile -Path $path -Text ($existing + "$comment fixture edit`n")
            $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', $case.Path)
            $run = Invoke-HookCommit -Fixture $fixture
            $run.Code | Should -Be 0 -Because "$($case.Path): $($run.Text)"
            $order = @($run.Tools | Where-Object { $_ -in 'Invoke-CatalogCompile', 'Invoke-CatalogEmbed' })
            $order | Should -Be @('Invoke-CatalogCompile', 'Invoke-CatalogEmbed')
        }
    }

    It 'runs the drafter over the supported locales, copying the English where nothing drafted, before the catalog pass' {
        $fixture = New-HookRepository -Name 'drafter-order' -Drafter 'exit 0'
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $drafter = @($run.Calls | Where-Object { $_.tool -eq 'New-Translation' })
        $drafter.Count | Should -Be 1
        @($drafter[0].args) | Should -Be @('-Staged', '-SupportedOnly', '-CopyEnglish', '-MaxRows', '0')
        [Array]::IndexOf($run.Tools, 'New-Translation') | Should -BeLessThan ([Array]::IndexOf($run.Tools, 'Invoke-CatalogCompile'))
    }

    It 'commits what the drafter staged' {
        $fixture = New-HookRepository -Name 'drafter-stages' -Drafter @'
$path = Join-Path $root 'globalization/catalogs/xx-XX/demo.json'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
[IO.File]::WriteAllText($path, "{ `"schema`": `"yuruna.catalog/v1`", `"domain`": `"demo`", `"locale`": `"xx-XX`", `"messages`": {} }`n")
& git -C $root add -- globalization/catalogs/xx-XX/demo.json
Write-Output 'pre-commit: WARNING: machine translation drafted 1 new or changed message(s) into xx-XX and staged them; 0 flagged, 0 not written.'
exit 0
'@
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Text | Should -Match 'machine translation drafted 1'
        Get-HeadName -Fixture $fixture | Should -Contain 'globalization/catalogs/xx-XX/demo.json'
    }

    It 'skips the drafter when YURUNA_TRANSLATE=0' {
        $fixture = New-HookRepository -Name 'drafter-off' -Drafter 'exit 0'
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture -Environment @{ YURUNA_TRANSLATE = '0' }
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Tools | Should -Not -Contain 'New-Translation'
        $run.Tools | Should -Contain 'Invoke-CatalogCompile'
    }

    It 'never fails the commit when the drafter fails' {
        $fixture = New-HookRepository -Name 'drafter-fails' -Drafter "Write-Output 'boom'`nexit 1"
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Text | Should -Match 'boom'
        Get-HeadName -Fixture $fixture | Should -Contain 'globalization/catalogs/en-US/demo.json'
    }

    It 'keeps exactly one retired_names line and the retired-name search key unique' {
        @(Select-String -LiteralPath $script:Hook -Pattern "^retired_names='").Count | Should -Be 1
        # Assembled, so this file is not itself a hit for the hook's retired-name pass.
        @(Select-String -LiteralPath $script:Hook -SimpleMatch ('status ' + 'server|status service')).Count | Should -Be 1
    }

    It 'warns for literal retired names while ignoring shell expansion and dotted lookalikes' {
        $fixture = New-HookRepository -Name 'retired-scan'
        $configKey = 'GH_TOKEN' + ':'
        $retiredPath = 'test/New-Pool' + '.ps1'
        $lookalike = 'test/New-Poolxps1'
        $content = '${GH_TOKEN:-} ' + $configKey + "`n" + $retiredPath + "`n" + $lookalike + "`n"
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text $content
        Write-FixtureFile -Path (Join-Path $fixture.Root 'expansion.txt') -Text '${GH_TOKEN:-}'
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'README.md', 'expansion.txt')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        @([regex]::Matches($run.Text, "retired name '$configKey'")).Count | Should -Be 1
        @([regex]::Matches($run.Text, "retired name '$([regex]::Escape($retiredPath))'")).Count | Should -Be 1
        $run.Text | Should -Not -Match 'expansion.txt'
        $run.Text | Should -Not -Match [regex]::Escape($lookalike)
    }

    It 'points a stale sourceHash at retranslation without private paths' {
        $fixture = New-HookRepository -Name 'stale-hint'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'compile-output.txt') -Text ("catalogs/xx-XX/demo.json: 'demo.k' sourceHash is stale; expected " + ('0' * 64) + "`n")
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 1 -Because $run.Text
        $run.Text | Should -Match 'retranslate'
        $run.Text | Should -Not -Match 'dev-only|localization-pro|Export-Localization'
    }

    It 'gives no retranslation hint for a planned locale''s warning' {
        $fixture = New-HookRepository -Name 'planned-warning'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'compile-output.txt') -Text ("WARN  catalogs/xx-XX/demo.json: 'demo.k' sourceHash is stale (planned locale; the entry is kept but not shipped)`nCatalog validation failed`n")
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 1 -Because $run.Text
        $run.Text | Should -Not -Match 'retranslate'
    }

    It 'refuses to stage in a partial commit' {
        $fixture = New-HookRepository -Name 'partial'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'compile-writes.txt') -Text "globalization/generated/browser/demo.js`n"
        Write-FixtureFile -Path (Join-Path $fixture.Root 'globalization/catalogs/en-US/demo.json') -Text "{ `"schema`": `"yuruna.catalog/v1`", `"domain`": `"demo`", `"locale`": `"en-US`", `"messages`": { `"demo.x`": { `"message`": `"X`", `"description`": `"X.`", `"lifecycle`": `"active`" } } }`n"
        $head = Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD')
        $run = Invoke-HookCommit -Fixture $fixture -Path @('globalization/catalogs/en-US/demo.json')
        $run.Code | Should -Be 1 -Because $run.Text
        $run.Text | Should -Match 'partial commit'
        Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD') | Should -Be $head
        Invoke-FixtureGit -Repository $fixture.Root -Argument @('diff', '--cached', '--name-only') | Should -BeNullOrEmpty
    }

    It 'regenerates the census on a clean tree and stages it' {
        $fixture = New-HookRepository -Name 'census-clean'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'inventory-stale') -Text ''
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'README.md')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Text | Should -Match 'pre-commit: WARNING: automation regenerated globalization/manifests/domain-inventory\.json and staged it\.'
        Get-HeadName -Fixture $fixture | Should -Contain 'globalization/manifests/domain-inventory.json'
        Invoke-FixtureGit -Repository $fixture.Root -Argument @('status', '--porcelain') | Should -BeNullOrEmpty
    }

    It 'still blocks the census on a dirty tree' {
        $fixture = New-HookRepository -Name 'census-dirty'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'inventory-stale') -Text ''
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'README.md')
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited twice`n"
        $head = Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 1 -Because $run.Text
        $run.Text | Should -Match 'the translation-surface census no longer reproduces from this tree'
        $run.Text | Should -Match ([regex]::Escape('(automatic regeneration needs this checkout clean apart from the index and the project checkout clean; stage or stash the rest.)'))
        @($run.Calls | Where-Object { $_.tool -eq 'Invoke-DomainInventory' -and $_.args -contains '-Update' }).Count | Should -Be 0
        Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD') | Should -Be $head
    }

    It 'still blocks the census when the project checkout is dirty' {
        $fixture = New-HookRepository -Name 'census-project-dirty'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'inventory-stale') -Text ''
        Write-FixtureFile -Path (Join-Path $fixture.Project 'notes.txt') -Text "untracked`n"
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'README.md')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 1 -Because $run.Text
        $run.Text | Should -Match 'automatic regeneration needs this checkout clean'
    }

    It 'regenerates the census in a commit -a, which exports its own index' {
        $fixture = New-HookRepository -Name 'census-commit-all'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'inventory-stale') -Text ''
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited`n"
        $run = Invoke-HookCommit -Fixture $fixture -Option @('-a')
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Text | Should -Match 'automation regenerated globalization/manifests/domain-inventory\.json and staged it'
        Get-HeadName -Fixture $fixture | Should -Contain 'globalization/manifests/domain-inventory.json'
    }

    It 'blocks the census in a commit -a when the project checkout is dirty' {
        $fixture = New-HookRepository -Name 'census-commit-all-dirty'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'inventory-stale') -Text ''
        Write-FixtureFile -Path (Join-Path $fixture.Project 'README.md') -Text "# Project fixture, edited`n"
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited`n"
        $run = Invoke-HookCommit -Fixture $fixture -Option @('-a')
        $run.Code | Should -Be 1 -Because $run.Text
        $run.Text | Should -Match 'automatic regeneration needs this checkout clean'
    }

    It 'blocks the census in a partial commit' {
        $fixture = New-HookRepository -Name 'census-partial'
        Write-FixtureFile -Path (Join-Path $fixture.Base 'inventory-stale') -Text ''
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited`n"
        $run = Invoke-HookCommit -Fixture $fixture -Path @('README.md')
        $run.Code | Should -Be 1 -Because $run.Text
        @($run.Calls | Where-Object { $_.tool -eq 'Invoke-DomainInventory' -and $_.args -contains '-Update' }).Count | Should -Be 0
    }

    It 'warns when a private test changes without its baseline' {
        $fixture = New-HookRepository -Name 'private-baseline' -PrivateRunner
        Write-FixtureFile -Path (Join-Path $fixture.Root 'dev-only/test/Test-Probe.Tests.ps1') -Text "Describe 'probe' { It 'runs' { 1 | Should -Be 1 } }`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'dev-only/test/Test-Probe.Tests.ps1')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Text | Should -Match 'WARNING: a private test file changed without re-recording'
    }

    It 'passes shellcheck' -Skip:(-not (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
        $output = & shellcheck -s sh --severity=warning -- $script:Hook 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
