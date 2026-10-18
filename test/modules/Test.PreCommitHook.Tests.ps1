<#PSScriptInfo
.VERSION 2026.10.18.1
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
    # SBOM generator tests cover content; these stubs isolate the other hook passes.
    Write-FixtureFile -Path (Join-Path $root 'tools/Sync-Sbom.py') -Text "raise SystemExit(0)`n"
    foreach ($tool in 'Test-AsciiNoBom', 'Test-SourceMetadata', 'Invoke-CatalogEmbed', 'Test-SuiteBaseline') {
        Write-FixtureFile -Path (Join-Path $root "tools/$tool.ps1") -Text (Get-StubText -Name $tool)
    }
    # The Pester 6.x answer comes from a flag file. A child pwsh cannot be shown a
    # machine without Pester 6.x: it adds the default module paths back whatever
    # PSModulePath says.
    Write-FixtureFile -Path (Join-Path $root 'tools/Install-TestModule.ps1') -Text (Get-StubText -Name 'Install-TestModule' -Behavior @'
if ([IO.File]::Exists((Join-Path $base 'pester6-missing'))) { exit 1 }
exit 0
'@)
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

    It 'checks the staged files for source metadata, quietly, before any generator runs' {
        $fixture = New-HookRepository -Name 'metadata-order'
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $call = @($run.Calls | Where-Object { $_.tool -eq 'Test-SourceMetadata' })
        $call.Count | Should -Be 1
        @($call[0].args) | Should -Be @('-Staged', '-Quiet')
        [Array]::IndexOf($run.Tools, 'Test-SourceMetadata') | Should -BeLessThan ([Array]::IndexOf($run.Tools, 'Invoke-CatalogCompile'))
    }

    It 'refuses the commit when the source-metadata gate fails, before the generators spend their time' {
        $fixture = New-HookRepository -Name 'metadata-fails'
        Write-FixtureFile -Path (Join-Path $fixture.Root 'tools/Test-SourceMetadata.ps1') -Text (Get-StubText -Name 'Test-SourceMetadata' -Behavior "Write-Output 'FAIL  new.sh  [copyright]'`nexit 1")
        Set-EnglishCatalog -Fixture $fixture
        $head = Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 1 -Because $run.Text
        $run.Text | Should -Match 'FAIL  new\.sh  \[copyright\]'
        $run.Text | Should -Match 'source-metadata gate failed'
        $run.Text | Should -Match 'tools/source-metadata\.exemptions\.json'
        $run.Tools | Should -Not -Contain 'Invoke-CatalogCompile'
        Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD') | Should -Be $head
    }

    It 'commits normally on a clone that has no source-metadata gate' {
        $fixture = New-HookRepository -Name 'metadata-absent'
        [IO.File]::Delete((Join-Path $fixture.Root 'tools/Test-SourceMetadata.ps1'))
        Set-EnglishCatalog -Fixture $fixture
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Tools | Should -Not -Contain 'Test-SourceMetadata'
        $run.Tools | Should -Contain 'Invoke-CatalogCompile'
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

    It 'refuses a test commit from a host without Pester 6.x, and names the install command' {
        $fixture = New-HookRepository -Name 'pester6-missing'
        Write-FixtureFile -Path (Join-Path $fixture.Root 'test/modules/Test.Probe.Tests.ps1') -Text "Describe 'probe' { It 'runs' { 1 | Should -Be 1 } }`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'test/modules/Test.Probe.Tests.ps1')
        Write-FixtureFile -Path (Join-Path (Split-Path -Parent $fixture.Root) 'pester6-missing') -Text ''
        $head = Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Not -Be 0 -Because $run.Text
        $run.Text | Should -Match 'pre-commit: Pester 6\.x is not installed, and a commit that stages a test file requires it'
        $run.Text | Should -Match 'Install-TestModule\.ps1'
        @($run.Calls | Where-Object { $_.tool -eq 'Install-TestModule' -and $_.args -contains '-Check' }).Count | Should -Be 1
        Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD') | Should -Be $head
    }

    It 'refuses a move that takes a test file out of test/modules without Pester 6.x' {
        $fixture = New-HookRepository -Name 'pester6-moved'
        Write-FixtureFile -Path (Join-Path $fixture.Root 'test/modules/Test.Probe.Tests.ps1') -Text "Describe 'probe' { It 'runs' { 1 | Should -Be 1 } }`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'test/modules/Test.Probe.Tests.ps1')
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('-c', 'core.hooksPath=', 'commit', '-q', '-m', 'probe suite')
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('mv', 'test/modules/Test.Probe.Tests.ps1', 'probe-archive.txt')
        Write-FixtureFile -Path (Join-Path (Split-Path -Parent $fixture.Root) 'pester6-missing') -Text ''
        $head = Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Not -Be 0 -Because $run.Text
        $run.Text | Should -Match 'Pester 6\.x is not installed'
        Invoke-FixtureGit -Repository $fixture.Root -Argument @('rev-parse', 'HEAD') | Should -Be $head
    }

    It 'commits a test file when Pester 6.x is installed' {
        $fixture = New-HookRepository -Name 'pester6-installed'
        Write-FixtureFile -Path (Join-Path $fixture.Root 'test/modules/Test.Probe.Tests.ps1') -Text "Describe 'probe' { It 'runs' { 1 | Should -Be 1 } }`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'test/modules/Test.Probe.Tests.ps1')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        @($run.Calls | Where-Object { $_.tool -eq 'Install-TestModule' -and $_.args -contains '-Check' }).Count | Should -Be 1
    }

    It 'asks for Pester 6.x only when a test file is staged' {
        $fixture = New-HookRepository -Name 'pester6-not-asked'
        Write-FixtureFile -Path (Join-Path (Split-Path -Parent $fixture.Root) 'pester6-missing') -Text ''
        Write-FixtureFile -Path (Join-Path $fixture.Root 'README.md') -Text "# Fixture, edited`n"
        $null = Invoke-FixtureGit -Repository $fixture.Root -Argument @('add', '--', 'README.md')
        $run = Invoke-HookCommit -Fixture $fixture
        $run.Code | Should -Be 0 -Because $run.Text
        $run.Tools | Should -Not -Contain 'Install-TestModule'
    }

    It 'passes shellcheck' -Skip:(-not (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
        $output = & shellcheck -s sh --severity=warning -- $script:Hook 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
    }
}

Describe 'encoding gate file discovery and bounded BOM reads' {
    BeforeAll {
        $script:EncodingSource = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools/Test-AsciiNoBom.ps1'
        function New-EncodingFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Creates only disposable encoding fixtures under TestDrive.')]
            param()
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Write-FixtureFile -Path (Join-Path $root 'tools/Test-AsciiNoBom.ps1') -Text ([IO.File]::ReadAllText($script:EncodingSource))
            Write-FixtureFile -Path (Join-Path $root 'test/modules/Test.Prelude.psm1') -Text @'
function Get-EntryPointExitCode { param($Outcome) if ($Outcome -eq 'Ok') { 0 } else { 1 } }
Export-ModuleMember -Function Get-EntryPointExitCode
'@
            $null = Invoke-FixtureGit -Repository $root -Argument @('init', '--quiet')
            return $root
        }
        function Invoke-EncodingFixture {
            param([string]$Root, [string[]]$Argument = @())
            $text = & pwsh -NoProfile -NonInteractive -File (Join-Path $Root 'tools/Test-AsciiNoBom.ps1') @Argument 2>&1 | Out-String
            return @{ Code = $LASTEXITCODE; Text = $text }
        }
    }

    It 'checks new and tracked <Extension> files without changing the ASCII scope' -ForEach @(
        @{ Extension = 'ps1' }, @{ Extension = 'PSM1' }, @{ Extension = 'psd1' },
        @{ Extension = 'sh' }, @{ Extension = 'bash' }, @{ Extension = 'css' },
        @{ Extension = 'json' }, @{ Extension = 'yml' }, @{ Extension = 'yaml' }
    ) {
        $root = New-EncodingFixture
        $file = Join-Path $root "nested/probe.$Extension"
        Write-FixtureFile -Path $file -Text ('ascii' + [char]0x00E9)
        $run = Invoke-EncodingFixture -Root $root -Argument @('-Quiet')
        $run.Code | Should -Be 1 -Because $run.Text
        $run.Text | Should -Match 'non-ASCII byte at offset 5'
        $null = Invoke-FixtureGit -Repository $root -Argument @('add', '-A')
        (Invoke-EncodingFixture -Root $root -Argument @('-Quiet')).Code | Should -Be 1
    }

    It 'excludes localized catalogs, unrelated types, ignored files, and absent tracked files' {
        $root = New-EncodingFixture
        $unicode = 'text' + [char]0x00E9
        Write-FixtureFile -Path (Join-Path $root 'globalization/catalogs/pt-BR/demo.json') -Text $unicode
        Write-FixtureFile -Path (Join-Path $root 'README.md') -Text $unicode
        Write-FixtureFile -Path (Join-Path $root '.gitignore') -Text "ignored.sh`n"
        Write-FixtureFile -Path (Join-Path $root 'ignored.sh') -Text $unicode
        Write-FixtureFile -Path (Join-Path $root 'deleted.sh') -Text $unicode
        $null = Invoke-FixtureGit -Repository $root -Argument @('add', '-A')
        Remove-Item -LiteralPath (Join-Path $root 'deleted.sh')
        $run = Invoke-EncodingFixture -Root $root -Argument @('-Quiet')
        $run.Code | Should -Be 0 -Because $run.Text
    }

    It 'checks brackets in an existing literal path' {
        $root = New-EncodingFixture
        $file = Join-Path $root 'probe[one].sh'
        Write-FixtureFile -Path $file -Text ([string][char]0x00E9)
        (Invoke-EncodingFixture -Root $root -Argument @('-Path', $file, '-Quiet')).Code | Should -Be 1
        (Invoke-EncodingFixture -Root $root -Argument @('-Quiet')).Code | Should -Be 1
    }

    It 'still resolves explicit wildcard inputs' {
        $root = New-EncodingFixture
        Write-FixtureFile -Path (Join-Path $root 'scripts/probe.sh') -Text ([string][char]0x00E9)
        (Invoke-EncodingFixture -Root $root -Argument @('-Path', (Join-Path $root 'scripts/*.sh'), '-Quiet')).Code | Should -Be 1
    }

    It 'fails when an explicit path matches nothing' {
        $root = New-EncodingFixture
        (Invoke-EncodingFixture -Root $root -Argument @('-Path', (Join-Path $root 'missing.sh'), '-Quiet')).Code | Should -Be 1
    }

    It 'detects <Label> using only the prefix' -ForEach @(
        @{ Label = 'UTF-8 BOM'; Bytes = @(239,187,191,65); Code = 1 },
        @{ Label = 'UTF-16 LE BOM'; Bytes = @(255,254); Code = 1 },
        @{ Label = 'UTF-16 BE BOM'; Bytes = @(254,255,65); Code = 1 },
        @{ Label = 'empty file'; Bytes = @(); Code = 0 },
        @{ Label = 'one-byte prefix'; Bytes = @(239); Code = 0 },
        @{ Label = 'two-byte prefix'; Bytes = @(239,187); Code = 0 },
        @{ Label = 'non-BOM Unicode'; Bytes = @(195,169,65); Code = 0 }
    ) {
        $root = New-EncodingFixture
        $file = Join-Path $root 'payload.bin'
        [IO.File]::WriteAllBytes($file, [byte[]]$Bytes)
        $run = Invoke-EncodingFixture -Root $root -Argument @('-Path', $file, '-BomOnly', '-Quiet')
        $run.Code | Should -Be $Code -Because $run.Text
    }

    It 'checks staged files in BOM-only mode without checking untracked BOMs' {
        $root = New-EncodingFixture
        $staged = Join-Path $root 'staged.txt'
        [IO.File]::WriteAllBytes($staged, [byte[]]@(195,169))
        [IO.File]::WriteAllBytes((Join-Path $root 'untracked.txt'), [byte[]]@(239,187,191))
        $null = Invoke-FixtureGit -Repository $root -Argument @('add', '--', 'staged.txt')
        (Invoke-EncodingFixture -Root $root -Argument @('-Staged', '-BomOnly', '-Quiet')).Code | Should -Be 0
        [IO.File]::WriteAllBytes($staged, [byte[]]@(239,187,191))
        $null = Invoke-FixtureGit -Repository $root -Argument @('add', '--', 'staged.txt')
        (Invoke-EncodingFixture -Root $root -Argument @('-Staged', '-BomOnly', '-Quiet')).Code | Should -Be 1
    }

    It 'allows a BOM sequence later in a large binary and closes the input stream' {
        $root = New-EncodingFixture
        $file = Join-Path $root 'payload.bin'
        $stream = [IO.File]::Create($file)
        try {
            $stream.SetLength(64MB)
            $stream.Position = 32MB
            $stream.Write([byte[]]@(239,187,191), 0, 3)
        } finally { $stream.Dispose() }
        $run = Invoke-EncodingFixture -Root $root -Argument @('-Path', $file, '-BomOnly', '-Quiet')
        $run.Code | Should -Be 0 -Because $run.Text
        $exclusive = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $exclusive.Dispose()
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
