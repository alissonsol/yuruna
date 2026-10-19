<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 425ba29c-8d06-4e43-bef3-ad4d3ee670fd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test fetch-execute integrity pester
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
    Pester guard on the guest fetch-and-execute integrity gate: the host must
    hand each guest a sha256 digest of the working-tree script it is about to
    fetch, and the guest must refuse bytes that do not match -- or bytes it was
    given no digest for.
.DESCRIPTION
    Two halves of one control:
      * Host side -- Get-FetchExecutionContext (Test.SequenceHandler.psm1) must
        bind the exact command and full working-tree digests in a private
        context, strip a ?query for path hashing, and fail before dispatch for
        traversal, absolute, or missing paths. The launch prefix is 16 chars.
        The context must never carry the manual override EXEC_ALLOW_UNVERIFIED,
        and the seeded launcher must refuse a context that tries to.
      * Guest side -- a digest is required by default. verify_sha256
        (automation/fetch-and-execute.sh) must return 0 on a match, 1 on a
        mismatch (override or not), 1 on an empty digest, 0 on an empty digest
        only under EXEC_ALLOW_UNVERIFIED=1 (with a banner), and 1 on an empty
        digest while EXEC_REQUIRE_SHA256=1 whatever the override says.
    The host half extracts the real function via the parser and exercises it (no
    module import, so no host I/O deps -- the same discipline as the sibling
    sequence tests). The guest half extracts the real shell function and runs it
    under bash, then drives the whole script end to end with the network, the
    terminal and sudo stubbed and its two system paths pointed at a scratch
    directory, so the exit code and "the payload did not run" are asserted
    rather than inferred from a return value. Both are skipped (pass) where bash
    is unavailable.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$modPath  = Join-Path $here 'Test.SequenceHandler.psm1'
$script:faePath  = Join-Path $repoRoot 'automation/fetch-and-execute.sh'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-GitHubSourceFixture {
    <#
        A throwaway checkout with its own remote and its own test.config.yml, so
        the two sources of "which repository is this" can be set independently.
        Built inside a function because a Describe body runs at discovery time
        and its variables are not in scope when the It bodies execute.
        -RemoteUrl '' leaves the checkout with no remote at all.
    #>
    param([string]$RemoteUrl, [string]$FrameworkUrl)
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ghsrc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'test') | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'test/test.config.yml') -Value "repositories:`n  frameworkUrl: $FrameworkUrl`n  ghToken: `"`"`n"
    Set-Content -LiteralPath (Join-Path $dir 'seed.txt') -Value 'seed'
    & git -C $dir init --quiet 2>&1 | Out-Null
    if ($RemoteUrl) { & git -C $dir remote add origin $RemoteUrl 2>&1 | Out-Null }
    & git -C $dir add -A 2>&1 | Out-Null
    & git -C $dir -c user.email='t@example.invalid' -c user.name='t' commit -qm 'seed' 2>&1 | Out-Null
    return $dir
}

function New-FetchProjectFixture {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [string]$Root,
        [string]$ProjectRemote = 'https://github.com/fixture/project.git',
        [switch]$PlainProject,
        [switch]$UnbornProject
    )
    if (-not $PSCmdlet.ShouldProcess($Root, 'Create isolated project checkout fixture')) { return }
    $project = Join-Path $Root 'project'
    $relative = 'project/example/website/test/ubuntu.server.26/website.sh'
    $payload = Join-Path $Root $relative
    $retry = Join-Path $Root 'automation/yuruna-retry.sh'
    foreach ($path in @($payload, $retry)) {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path)
        [IO.File]::WriteAllText($path, "printf 'fixture payload\n'`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $Root '.gitignore'), "project/`n", [Text.UTF8Encoding]::new($false))
    & git -C $Root init --quiet 2>&1 | Out-Null
    & git -C $Root remote add origin 'https://github.com/fixture/framework.git' 2>&1 | Out-Null
    & git -C $Root add -A 2>&1 | Out-Null
    & git -C $Root -c user.email='fixture@example.invalid' -c user.name='Fixture' -c core.hooksPath=.no-hooks commit -qm framework 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the framework fixture.' }
    $frameworkRef = [string](& git -C $Root rev-parse HEAD)
    $projectRef = ''
    if (-not $PlainProject) {
        & git -C $project init --quiet 2>&1 | Out-Null
        if ($ProjectRemote) { & git -C $project remote add origin $ProjectRemote 2>&1 | Out-Null }
        if (-not $UnbornProject) {
            & git -C $project add -A 2>&1 | Out-Null
            & git -C $project -c user.email='fixture@example.invalid' -c user.name='Fixture' -c core.hooksPath=.no-hooks commit -qm project 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not commit the project fixture.' }
            $projectRef = [string](& git -C $project rev-parse HEAD)
        }
    }
    return @{ Root = $Root; ProjectRoot = $project; RelativePath = $relative; Payload = $payload;
        FrameworkRef = $frameworkRef.Trim(); ProjectRef = $projectRef.Trim() }
}

function Invoke-BashDriver {
    <#
        Runs a file-backed script so nested shells cannot consume the driver's
        stdin or leave a large heredoc blocked in a native Windows pipe.
    #>
    param([string]$BashPath, [string]$Script)
    $driverPath = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($driverPath, $Script.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        $launch = @'
driver=$1
if command -v wslpath >/dev/null 2>&1; then
    driver=$(wslpath -u "$driver") || exit 125
elif command -v cygpath >/dev/null 2>&1; then
    driver=$(cygpath -u "$driver") || exit 125
fi
exec bash "$driver"
'@
        $output = (& $BashPath -c $launch.Replace("`r`n", "`n") 'yuruna-integrity-fixture' $driverPath | Out-String).Trim()
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally { Remove-Item -LiteralPath $driverPath -Force -ErrorAction SilentlyContinue }
}

# Exercise the production context builder without importing host I/O modules.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.GitHubSource.psm1') -Force -DisableNameChecking
$modAst = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$null)
foreach ($name in @('Get-FetchExecutionCommand', 'Get-FetchExecutionContext')) {
    $fnAst = $modAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fnAst) { throw "Missing function: $name" }
    . ([scriptblock]::Create($fnAst.Extent.Text))
}
$script:NonzeroScriptExitSentinel = 'NONZERO SCRIPT EXIT:'
$sample = 'guest/ubuntu.server.26/ubuntu.server.26.update.sh'
$script:sampleHash = (Get-FileHash -LiteralPath (Join-Path $repoRoot $sample) -Algorithm SHA256).Hash.ToLowerInvariant()
$script:retryHash = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'automation/yuruna-retry.sh') -Algorithm SHA256).Hash.ToLowerInvariant()
$script:fetchContext = @{ Step = @{}; RepoRoot = $repoRoot; StepInvocationId = 'step-123'; SequenceInvocationId = 'sequence-456' }
# The guest context script keeps state in an associative array, which needs
# bash 4. It runs on Linux guests; the stock macOS /bin/bash is 3.2 and stops
# at that line, so the cases that run it under the host's bash skip there.
$hostBash = Get-Command bash -ErrorAction SilentlyContinue
$script:hostBashHasAssociativeArrays = [bool]$hostBash -and ((& $hostBash.Source -c 'declare -A probe 2>/dev/null && echo yes') -eq 'yes')
}

Describe 'Get-FetchExecutionContext (host-side integrity binding)' {
    It 'uses an exact 16-character launch prefix and full SHA-256 digests' {
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine "/usr/local/lib/yuruna/fetch-and-execute.sh $sample" -WarningAction SilentlyContinue
        $result.Prefix.Length | Should -Be 16
        $result.Prefix | Should -Match '^yfe [0-9a-f]{11} $'
        $result.Launch | Should -BeExactly ($result.Prefix + "bash -c '/usr/local/lib/yuruna/fetch-and-execute.sh $sample'")
        $result.Fields.EXEC_REQUIRE_SHA256 | Should -BeExactly '1'
        $result.Fields.E_SHA | Should -BeExactly $script:sampleHash
        $result.Fields.E_RETRY_SHA | Should -BeExactly $script:retryHash
        $result.Fields.E_FB_REF | Should -Match '^[0-9a-f]{40}$'
        $result.Fields.E_SI | Should -BeExactly 'step-123'
        $result.Fields.E_QI | Should -BeExactly 'sequence-456'
        $result.Bytes.Length | Should -BeLessOrEqual 4096
        $result.Command | Should -Not -Match 'NONZERO SCRIPT EXIT:'
    }
    It 'never carries the manual unverified override, which only an operator may type' {
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine "/usr/local/lib/yuruna/fetch-and-execute.sh $sample" -WarningAction SilentlyContinue
        $result.Fields.Contains('EXEC_ALLOW_UNVERIFIED') | Should -BeFalse
        [Text.Encoding]::UTF8.GetString($result.Bytes) | Should -Not -Match 'EXEC_ALLOW_UNVERIFIED'
        $result.Command | Should -Not -Match 'EXEC_ALLOW_UNVERIFIED'
        # Neither the launcher's field allowlist nor its export list may name it.
        $launcher = [IO.File]::ReadAllText((Join-Path $repoRoot 'automation/yuruna-fetch-context.sh'))
        $launcher | Should -Not -Match 'EXEC_ALLOW_UNVERIFIED'
    }
    It 'strips a query before hashing but binds the complete original command' {
        $command = "fetch-and-execute.sh $sample" + '?nocache=9'
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine $command -WarningAction SilentlyContinue
        $result.Fields.rel | Should -BeExactly $sample
        $result.Fields.E_SHA | Should -BeExactly $script:sampleHash
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($command))).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        $result.Fields.cmd_sha | Should -BeExactly $digest
    }
    It 'fails before dispatch on traversal, absolute, missing, or unserved paths' {
        foreach ($command in @(
            'fetch-and-execute.sh ../../etc/passwd',
            'fetch-and-execute.sh /etc/passwd',
            'fetch-and-execute.sh guest/does-not-exist.sh'
        )) {
            { Get-FetchExecutionContext -Context $script:fetchContext -CommandLine $command -WarningAction SilentlyContinue } | Should -Throw
        }
        $missingRoot = @{ Step = @{}; RepoRoot = ''; StepInvocationId = 'x'; SequenceInvocationId = 'y' }
        { Get-FetchExecutionContext -Context $missingRoot -CommandLine "fetch-and-execute.sh $sample" } | Should -Throw
    }
    It 'preserves observations but has no fabricated integrity fields for non-fetch commands' {
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine ('printf caf' + [char]0x00e9)
        $result.Fields.E_SI | Should -BeExactly 'step-123'
        $result.Fields.Contains('E_SHA') | Should -BeFalse
        $result.Fields.Contains('EXEC_REQUIRE_SHA256') | Should -BeFalse
    }
    It 'keeps the configured token out of the context and launch' {
        # A throwaway checkout carries a synthetic token, so the case does not
        # depend on a secret configured on the host that runs the suite.
        $token = 'ghp_' + ('Yz9' * 12)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-token-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            foreach ($relative in @($sample, 'automation/yuruna-retry.sh')) {
                $target = Join-Path $dir $relative
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
                Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $target
            }
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'test')
            Set-Content -LiteralPath (Join-Path $dir 'test/test.config.yml') -Value "repositories:`n  frameworkUrl: https://github.com/example/framework`n  ghToken: `"$token`"`n"
            & git -C $dir init --quiet 2>&1 | Out-Null
            & git -C $dir remote add origin 'https://github.com/example/framework' 2>&1 | Out-Null
            & git -C $dir add -A 2>&1 | Out-Null
            & git -C $dir -c user.email='t@example.invalid' -c user.name='t' commit -qm 'seed' 2>&1 | Out-Null
            (Get-YurunaGitHubSource -RepoRoot $dir).Token | Should -BeExactly $token -Because 'the fixture must actually configure the token'
            $context = @{ Step = @{}; RepoRoot = $dir; StepInvocationId = 'step-123'; SequenceInvocationId = 'sequence-456' }
            $result = Get-FetchExecutionContext -Context $context -CommandLine "fetch-and-execute.sh $sample" -WarningAction SilentlyContinue
            $result.Command | Should -Not -Match ([regex]::Escape($token))
            $result.Launch | Should -Not -Match ([regex]::Escape($token))
            [Text.Encoding]::UTF8.GetString($result.Bytes) | Should -Not -Match ([regex]::Escape($token))
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'preserves the sensitive-step profile opt-out and full invocation IDs' {
        $context = @{ Step = @{ sensitive = $true }; RepoRoot = $repoRoot; StepInvocationId = 'step-sensitive-123'; SequenceInvocationId = 'sequence-sensitive-456' }
        $result = Get-FetchExecutionContext -Context $context -CommandLine 'true'
        $result.Fields.EXEC_PROFILE | Should -BeExactly '0'
        $result.Fields.EXEC_KEEP_PROFILE | Should -BeExactly '0'
        $result.Fields.E_SI | Should -BeExactly 'step-sensitive-123'
        $result.Fields.E_QI | Should -BeExactly 'sequence-sensitive-456'
    }
    It 'reserves a distinct context identifier for each explicit retry' {
        $first = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine 'true'
        $retry = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine 'true'
        $first.Id | Should -Not -Be $retry.Id
        $first.Fields.cmd_sha | Should -BeExactly $retry.Fields.cmd_sha
        $first.Launch | Should -Not -Be $retry.Launch
    }
    It 'requires the served retry library before dispatch' {
        $path = Join-Path $TestDrive 'guest/payload.sh'
        $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
        [IO.File]::WriteAllText($path, 'true')
        $context = @{ Step = @{}; RepoRoot = $TestDrive; StepInvocationId = 'step'; SequenceInvocationId = 'sequence' }
        { Get-FetchExecutionContext -Context $context -CommandLine 'fetch-and-execute.sh guest/payload.sh' } | Should -Throw '*YFE_RETRY_LIB_MISSING*'
    }
    It 'binds the transferred base64 bytes, count, and SHA-256 to one preparation' {
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine 'printf ready'
        $result.Preparation -match "^printf '%s' '([A-Za-z0-9+/=]+)' \| yfe --prepare ([0-9a-f]{11}) ([0-9]+) ([0-9a-f]{64})$" | Should -BeTrue
        $encoded = $Matches[1]; $id = $Matches[2]; $count = [int]$Matches[3]; $digest = $Matches[4]
        $decoded = [Convert]::FromBase64String($encoded)
        $decoded.Length | Should -Be $count
        $id | Should -BeExactly $result.Id
        [Convert]::ToBase64String($decoded) | Should -BeExactly ([Convert]::ToBase64String($result.Bytes))
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($sha256.ComputeHash($decoded)).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        $actual | Should -BeExactly $digest
    }
    It 'keeps UTF-8 command binding culture independent and the context BOM-free' {
        $previous = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $command = 'printf ' + [char]0x03bb
            $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine $command
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try { $expected = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($command))).Replace('-', '').ToLowerInvariant() }
            finally { $sha256.Dispose() }
            $result.Fields.cmd_sha | Should -BeExactly $expected
            $result.Bytes[0] | Should -Be ([byte][char]'Y')
            $result.Prefix.Length | Should -Be 16
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previous }
    }
    It 'gives all three supplied commands the expected compact launch lengths' {
        $examples = @(
            @{ path = $sample; length = 118 },
            @{ path = 'guest/ubuntu.server.26/ubuntu.server.26.k8s.sh'; length = 115 },
            @{ path = 'project/example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh'; length = 155 }
        )
        $fixtureRoot = Join-Path $TestDrive 'compact-launch'
        $retry = Join-Path $fixtureRoot 'automation/yuruna-retry.sh'
        $null = New-Item -ItemType Directory -Path (Split-Path $retry) -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'automation/yuruna-retry.sh') -Destination $retry
        $context = @{ Step = @{}; RepoRoot = $fixtureRoot; StepInvocationId = 'step'; SequenceInvocationId = 'sequence' }
        foreach ($example in $examples) {
            # Launch length depends on the served path. An isolated payload
            # makes the project case independent of a test-cycle checkout.
            $payload = Join-Path $fixtureRoot $example.path
            $null = New-Item -ItemType Directory -Path (Split-Path $payload) -Force
            [IO.File]::WriteAllText($payload, "printf '%s' 'fixture payload'`n", [Text.UTF8Encoding]::new($false))
            $result = Get-FetchExecutionContext -Context $context -CommandLine "/usr/local/lib/yuruna/fetch-and-execute.sh $($example.path)" -WarningAction SilentlyContinue
            $result.Launch.Length | Should -Be $example.length
            $result.Prefix.Length | Should -Be 16
            $result.Fields.E_SHA | Should -BeExactly (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
            Remove-Item -LiteralPath $payload
            { Get-FetchExecutionContext -Context $context -CommandLine "fetch-and-execute.sh $($example.path)" } | Should -Throw '*YFE_PAYLOAD_MISSING*'
        }
    }
    It 'executes the host-built preparation and launch without changing Unicode or shell quoting' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        if (-not $script:hostBashHasAssociativeArrays) { Set-ItResult -Skipped -Because 'the host bash predates 4.0 (no associative arrays); the context script targets a Linux guest'; return }
        $command = "printf '%s|' `"it's`"; printf '%s' 'caf$([char]0x00e9)'"
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine $command
        $driver = @'
set -e
export HOME=$(mktemp -d)
trap 'rm -rf -- "$HOME"' EXIT
yfe() { bash automation/yuruna-fetch-context.sh "$@"; }
'@ + "`n$($result.Command)"
        # Native output is decoded with the console code page (OEM on Windows), which
        # would turn the UTF-8 bytes of the accented letter into mojibake.
        $priorEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            $run = Invoke-BashDriver -BashPath $bash.Source -Script $driver
        } finally { [Console]::OutputEncoding = $priorEncoding }
        $run.ExitCode | Should -Be 0
        $run.Output | Should -BeExactly ("it's|caf" + [char]0x00e9)
    }
    It 'keeps the private context mask out of the launched guest command' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        if (-not $script:hostBashHasAssociativeArrays) { Set-ItResult -Skipped -Because 'the host bash predates 4.0 (no associative arrays); the context script targets a Linux guest'; return }
        foreach ($mask in @('0022', '0027')) {
            $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine 'umask'
            $driver = @'
set -e
export HOME=$(mktemp -d)
trap 'rm -rf -- "$HOME"' EXIT
yfe() { bash automation/yuruna-fetch-context.sh "$@"; }
'@ + "`numask $mask`n$($result.Command)"
            $run = Invoke-BashDriver -BashPath $bash.Source -Script $driver
            $run.ExitCode | Should -Be 0
            $run.Output | Should -BeExactly $mask
        }
    }
}

Describe 'Fetch context guest seeding' {
    It 'embeds the exact launcher bytes in the shared seed builder' {
        $scripts = Get-YurunaGuestScriptBase64 -RepoRoot $repoRoot
        $actual = [Convert]::FromBase64String($scripts.FetchContext)
        $expected = [IO.File]::ReadAllBytes((Join-Path $repoRoot 'automation/yuruna-fetch-context.sh'))
        [Convert]::ToBase64String($actual) | Should -BeExactly ([Convert]::ToBase64String($expected))
    }

    It 'installs the launcher in both shared Linux guest bases' {
        foreach ($name in @('ubuntu.server.base.user-data', 'amazon.linux.2023.base.user-data')) {
            $seed = [IO.File]::ReadAllText((Join-Path $repoRoot "host/vmconfig/$name"))
            $seed | Should -Match '/usr/local/bin/yfe'
            $seed | Should -Match 'YURUNA_FETCH_CONTEXT_BASE64_PLACEHOLDER'
        }
    }

    It 'refuses a context that carries the manual unverified override, even inside an enforced one' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        if (-not $script:hostBashHasAssociativeArrays) { Set-ItResult -Skipped -Because 'the host bash predates 4.0 (no associative arrays); the context script targets a Linux guest'; return }
        $built = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine "/usr/local/lib/yuruna/fetch-and-execute.sh $sample" -WarningAction SilentlyContinue
        $builtText = [Text.Encoding]::UTF8.GetString($built.Bytes)
        $builtText | Should -Match 'EXEC_REQUIRE_SHA256=' -Because 'the fixture must be an enforced context to prove the override cannot ride inside one'
        $override = 'EXEC_ALLOW_UNVERIFIED=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('1')) + "`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($builtText + $override)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        $encoded = [Convert]::ToBase64String($bytes)
        $driver = @'
export HOME=$(mktemp -d)
trap 'rm -rf -- "$HOME"' EXIT
yfe() { bash automation/yuruna-fetch-context.sh "$@"; }
'@ + "`nprintf '%s' '$encoded' | yfe --prepare $($built.Id) $($bytes.Length) $digest 2>&1; echo `"STATUS=`$?`""
        Push-Location $repoRoot
        try { $run = Invoke-BashDriver -BashPath $bash.Source -Script $driver } finally { Pop-Location }
        $run.Output | Should -Match 'YFE_CONTEXT_FIELD'
        $run.Output | Should -Match 'STATUS=125'
    }
}

Describe 'Project payloads keep their own pinned fallback identity' {
    It 'binds project and framework repository pins independently without changing the served path' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'independent')
        $context = @{ Step = @{}; RepoRoot = $fixture.Root; StepInvocationId = 'project-step'; SequenceInvocationId = 'project-sequence' }
        $result = Get-FetchExecutionContext -Context $context -CommandLine "fetch-and-execute.sh $($fixture.RelativePath)"
        $result.Fields.rel | Should -BeExactly $fixture.RelativePath
        $result.Fields.E_FB_REPO | Should -BeExactly 'fixture/framework'
        $result.Fields.E_FB_REF | Should -BeExactly $fixture.FrameworkRef
        $result.Fields.E_PROJECT_REPO | Should -BeExactly 'fixture/project'
        $result.Fields.E_PROJECT_REF | Should -BeExactly $fixture.ProjectRef
        $fixture.FrameworkRef | Should -Not -Be $fixture.ProjectRef
        $result.Fields.E_SHA | Should -BeExactly (Get-FileHash -LiteralPath $fixture.Payload -Algorithm SHA256).Hash.ToLowerInvariant()
        $result.Fields.E_RETRY_SHA | Should -BeExactly (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'automation/yuruna-retry.sh') -Algorithm SHA256).Hash.ToLowerInvariant()
        $result.Launch | Should -Match ([regex]::Escape($fixture.RelativePath))
        $result.Bytes.Length | Should -BeLessOrEqual 4096
    }

    It 'uses the project checkout remote even when its clone configuration names another repository' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'remote') -ProjectRemote 'git@github.com:fixture/actual-project.git'
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture.ProjectRoot 'test') -Force
        [IO.File]::WriteAllText((Join-Path $fixture.ProjectRoot 'test/test.config.yml'), "repositories:`n  frameworkUrl: https://github.com/fixture/configured-mirror`n", [Text.UTF8Encoding]::new($false))
        $result = Get-FetchExecutionContext -Context @{ Step = @{}; RepoRoot = $fixture.Root } -CommandLine "fetch-and-execute.sh $($fixture.RelativePath)" -WarningAction SilentlyContinue
        $result.Fields.E_PROJECT_REPO | Should -BeExactly 'fixture/actual-project'
        $result.Fields.E_PROJECT_REF | Should -BeExactly $fixture.ProjectRef
    }

    It 'never inherits framework coordinates from a plain ignored project directory' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'plain') -PlainProject
        $result = Get-FetchExecutionContext -Context @{ Step = @{}; RepoRoot = $fixture.Root } -CommandLine "fetch-and-execute.sh $($fixture.RelativePath)" -WarningAction SilentlyContinue
        $result.Fields.Contains('E_PROJECT_REPO') | Should -BeFalse
        $result.Fields.Contains('E_PROJECT_REF') | Should -BeFalse
        $result.Fields.E_FB_REPO | Should -BeExactly 'fixture/framework'
        $result.Fields.E_SHA | Should -Match '^[0-9a-f]{64}$'
    }

    It 'leaves project fallback unavailable when the project has no committed HEAD' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'unborn') -UnbornProject
        $result = Get-FetchExecutionContext -Context @{ Step = @{}; RepoRoot = $fixture.Root } -CommandLine "fetch-and-execute.sh $($fixture.RelativePath)" -WarningAction SilentlyContinue
        $result.Fields.Contains('E_PROJECT_REPO') | Should -BeFalse
        $result.Fields.Contains('E_PROJECT_REF') | Should -BeFalse
    }

    It 'leaves project fallback unavailable for a non-GitHub remote' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'non-github') -ProjectRemote 'https://example.invalid/fixture/project.git'
        $result = Get-FetchExecutionContext -Context @{ Step = @{}; RepoRoot = $fixture.Root } -CommandLine "fetch-and-execute.sh $($fixture.RelativePath)" -WarningAction SilentlyContinue
        $result.Fields.Contains('E_PROJECT_REPO') | Should -BeFalse
        $result.Fields.Contains('E_PROJECT_REF') | Should -BeFalse
    }

    It 'never substitutes a configured framework repository for an unproven project remote' -ForEach @(
        @{ Name='missing'; Remote='' },
        @{ Name='non-github'; Remote='https://example.invalid/fixture/project.git' }
    ) {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive "unproven-$Name") -ProjectRemote $Remote
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.ProjectRoot 'test'))
        [IO.File]::WriteAllText((Join-Path $fixture.ProjectRoot 'test/test.config.yml'), "repositories:`n  frameworkUrl: https://github.com/fixture/framework`n", [Text.UTF8Encoding]::new($false))
        $result = Get-FetchExecutionContext -Context @{Step=@{};RepoRoot=$fixture.Root} -CommandLine "fetch-and-execute.sh $($fixture.RelativePath)" -WarningAction SilentlyContinue
        $result.Fields.Contains('E_PROJECT_REPO') | Should -BeFalse
        $result.Fields.Contains('E_PROJECT_REF') | Should -BeFalse
        $result.Fields.E_FB_REPO | Should -Be 'fixture/framework'
    }

    It 'warns about a modified project payload and keeps its working-tree digest and original commit pin' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'modified')
        [IO.File]::WriteAllText($fixture.Payload, "printf 'changed payload\n'`n", [Text.UTF8Encoding]::new($false))
        $result = Get-FetchExecutionContext -Context @{ Step = @{}; RepoRoot = $fixture.Root } -CommandLine "fetch-and-execute.sh $($fixture.RelativePath)" -WarningVariable sourceWarnings -WarningAction SilentlyContinue
        @($sourceWarnings).Count | Should -BeGreaterThan 0
        ($sourceWarnings -join "`n") | Should -Match ([regex]::Escape($fixture.RelativePath))
        $result.Fields.E_PROJECT_REF | Should -BeExactly $fixture.ProjectRef
        $result.Fields.E_SHA | Should -BeExactly (Get-FileHash -LiteralPath $fixture.Payload -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'keeps synthetic project credentials out of the transferable context' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'private')
        $token = 'ghp_' + ('Fixture9' * 5)
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture.ProjectRoot 'test') -Force
        [IO.File]::WriteAllText((Join-Path $fixture.ProjectRoot 'test/test.config.yml'), "repositories:`n  ghToken: $token`n", [Text.UTF8Encoding]::new($false))
        $result = Get-FetchExecutionContext -Context @{ Step = @{}; RepoRoot = $fixture.Root } -CommandLine "fetch-and-execute.sh $($fixture.RelativePath)"
        $result.Fields.E_PROJECT_REPO | Should -BeExactly 'fixture/project'
        $result.Command | Should -Not -Match ([regex]::Escape($token))
        [Text.Encoding]::UTF8.GetString($result.Bytes) | Should -Not -Match ([regex]::Escape($token))
    }

    It 'does not attach project coordinates to framework commands' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'framework-only')
        $result = Get-FetchExecutionContext -Context @{ Step = @{}; RepoRoot = $fixture.Root } -CommandLine 'fetch-and-execute.sh automation/yuruna-retry.sh'
        $result.Fields.Contains('E_PROJECT_REPO') | Should -BeFalse
        $result.Fields.Contains('E_PROJECT_REF') | Should -BeFalse
        $result.Fields.E_FB_REF | Should -BeExactly $fixture.FrameworkRef
    }

    It 'keeps query-bearing project commands bound to the original command and query-free file' {
        $fixture = New-FetchProjectFixture -Root (Join-Path $TestDrive 'project-query')
        $command = "fetch-and-execute.sh $($fixture.RelativePath)?nocache=123"
        $result = Get-FetchExecutionContext -Context @{ Step = @{}; RepoRoot = $fixture.Root } -CommandLine $command
        $result.Fields.rel | Should -BeExactly $fixture.RelativePath
        $result.Fields.E_PROJECT_REF | Should -BeExactly $fixture.ProjectRef
        $result.Launch | Should -Match '\?nocache=123'
    }
}

Describe 'Get-YurunaGitHubSource / ConvertTo-GitHubRepoSlug' {
    It 'reduces every remote-URL shape to owner/repo' {
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'https://github.com/o/r') -Expected 'o/r'
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'https://github.com/o/r.git') -Expected 'o/r'
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'git@github.com:o/r.git') -Expected 'o/r'
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'ssh://git@github.com/o/r') -Expected 'o/r'
    }
    It 'returns empty for a non-GitHub URL, so no fallback is attempted' {
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'https://gitlab.com/o/r') -Expected ''
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug '') -Expected ''
    }
    It 'resolves this repo to a slug and a 40-char commit' {
        $s = Get-YurunaGitHubSource -RepoRoot $repoRoot
        Assert-True ($s.Repo -match '^[^/]+/[^/]+$') "repo slug shape, got '$($s.Repo)'"
        Assert-True ($s.Ref  -match '^[0-9a-f]{40}$') "commit sha shape, got '$($s.Ref)'"
    }

    # Repo and Ref address ONE blob on raw.githubusercontent.com. Ref is always
    # this checkout's HEAD, so a slug taken from anywhere else builds a URL for a
    # commit that repository does not contain -- a 404 no token can open, and one
    # that reads as a permissions problem rather than the mismatch it is.
    It 'takes the slug from the checkout, not from a frameworkUrl naming another repo' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://github.com/owner/checkout-repo.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningAction SilentlyContinue
            Assert-StringEqual -Actual $s.Repo -Expected 'owner/checkout-repo' -Because 'the slug must name the repository the commit came from'
            Assert-StringEqual -Actual $s.Ref -Expected (& git -C $dir rev-parse HEAD).Trim() -Because 'the ref is still this checkout HEAD'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'reports the disagreement instead of silently preferring one side' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://github.com/owner/checkout-repo.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $w = @()
            $null = Get-YurunaGitHubSource -RepoRoot $dir -WarningVariable w -WarningAction SilentlyContinue
            Assert-True ($w.Count -gt 0) 'a repo mismatch must be reported'
            Assert-True ("$w" -match 'checkout-repo')   'the warning names the checkout repository'
            Assert-True ("$w" -match 'configured-repo') 'the warning names the configured repository'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'stays quiet when the checkout and the configured URL agree' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://github.com/owner/same-repo.git' `
                                       -FrameworkUrl 'https://github.com/owner/same-repo'
        try {
            $w = @()
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningVariable w -WarningAction SilentlyContinue
            Assert-StringEqual -Actual $s.Repo -Expected 'owner/same-repo' -Because 'the agreed slug is used'
            Assert-StringEqual -Actual $w.Count -Expected 0 -Because 'agreement is not worth a warning'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    # A checkout with no remote cannot prove where HEAD lives, so the configured
    # URL is the only candidate left. It is still offered -- a fallback that might
    # work beats none -- but not silently, because the 404 it can produce looks
    # exactly like a missing token.
    It 'falls back to frameworkUrl only when the checkout has no remote, and says so' {
        $dir = Get-GitHubSourceFixture -RemoteUrl '' -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $w = @()
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningVariable w -WarningAction SilentlyContinue
            Assert-StringEqual -Actual $s.Repo -Expected 'owner/configured-repo' -Because 'with no remote, the configured URL is all there is'
            Assert-True ($w.Count -gt 0) 'the unproven pairing must be reported'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'keeps frameworkUrl as the clone URL even when the fetch slug differs' {
        # FrameworkUrl answers "where do I clone the framework from", which is a
        # different question from "where do these exact bytes live". Only the
        # second has to agree with the pinned commit.
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://github.com/owner/checkout-repo.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningAction SilentlyContinue
            Assert-StringEqual -Actual $s.FrameworkUrl -Expected 'https://github.com/owner/configured-repo' -Because 'the clone URL still comes from config'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'ignores a non-GitHub remote so a mirror cannot become the fetch source' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://gitlab.com/owner/mirror.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningAction SilentlyContinue
            Assert-StringEqual -Actual (Get-YurunaCheckoutRemoteUrl -RepoRoot $dir) -Expected '' -Because 'a non-GitHub remote cannot serve raw content'
            Assert-StringEqual -Actual $s.Repo -Expected 'owner/configured-repo' -Because 'so the configured URL answers instead'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}

Describe 'verify_sha256 (guest-side gate)' {
    BeforeAll {
        # The real function, lifted out of the script, driven under bash. Each
        # case reports the status and the two streams separately: the refusal
        # and the banner are promised on stderr, and one that drifted onto stdout
        # would land in the payload's log instead of in front of the operator.
        # The script goes in on stdin so there is no Windows/POSIX temp-path to
        # translate for the bash child (the suite also runs on Linux/macOS hosts).
        $vf = [regex]::Match((Get-Content -Raw -LiteralPath $script:faePath), '(?ms)^verify_sha256\(\)\s*\{.*?^\}')
        $script:verifyFunction = if ($vf.Success) { $vf.Value } else { $null }

        function Invoke-VerifyCase {
            param(
                [ValidateSet('good', 'wrong', 'empty')][string]$Digest = 'empty',
                [string[]]$Setup = @(),         # bash lines run before the call: exports of the environment under test
                [string]$VarName = '',          # the optional 4th argument
                [string]$Label = 'guest/example.sh'
            )
            $digestWord = switch ($Digest) { 'good' { '"$good"' } 'wrong' { 'deadbeef' } default { "''" } }
            $template = @'
unset EXEC_REQUIRE_SHA256 EXEC_ALLOW_UNVERIFIED FETCH_SOURCE GH_REPO GH_REF HOST_BASE
__SETUP__
tf=$(mktemp); printf 'yuruna integrity probe' > "$tf"
good=$( (sha256sum "$tf" 2>/dev/null || shasum -a 256 "$tf") | awk '{print $1}')
rc=0
verify_sha256 "$tf" __DIGEST__ '__LABEL__' __VAR__ >"$tf.out" 2>"$tf.err" || rc=$?
echo "RC=$rc"
echo '@@STDOUT'; cat "$tf.out"; echo
echo '@@STDERR'; cat "$tf.err"; echo
echo '@@END'
rm -f "$tf" "$tf.out" "$tf.err"
'@
            $driver = $template.Replace('__SETUP__', ($Setup -join "`n")).Replace('__DIGEST__', $digestWord).Replace('__LABEL__', $Label).Replace('__VAR__', $VarName)
            $run = Invoke-BashDriver -BashPath (Get-Command bash).Source -Script ($script:verifyFunction + "`n" + $driver)
            $m = [regex]::Match($run.Output, '(?s)RC=(\d+)\s+@@STDOUT\r?\n(.*?)\r?\n@@STDERR\r?\n(.*?)\r?\n@@END')
            if (-not $m.Success) { throw "verify_sha256 driver produced no result block:`n$($run.Output)" }
            return [pscustomobject]@{
                Rc     = [int]$m.Groups[1].Value
                Stdout = $m.Groups[2].Value
                Stderr = $m.Groups[3].Value
            }
        }
    }

    It 'finds the function the cases below depend on' {
        Assert-True ($null -ne $script:verifyFunction) 'verify_sha256 found in fetch-and-execute.sh'
    }

    It 'returns 0 on a matching digest and 1 on a mismatching one, quietly in the first case' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $ok = Invoke-VerifyCase -Digest good
        $ok.Rc | Should -Be 0
        $ok.Stdout | Should -Match 'sha256 verified \(guest/example\.sh\)'
        $ok.Stderr.Trim() | Should -BeNullOrEmpty
        $bad = Invoke-VerifyCase -Digest wrong
        $bad.Rc | Should -Be 1
        $bad.Stderr | Should -Match 'INTEGRITY MISMATCH'
    }

    It 'refuses an empty digest by default, on stderr, naming how to supply one' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $run = Invoke-VerifyCase -Digest empty
        $run.Rc | Should -Be 1
        $run.Stdout.Trim() | Should -BeNullOrEmpty
        $run.Stderr | Should -Match 'NO EXPECTED DIGEST'
        $run.Stderr | Should -Match 'guest/example\.sh'
        $run.Stderr | Should -Match 'E_SHA=<64 hex digits>'
        $run.Stderr | Should -Match 'EXEC_ALLOW_UNVERIFIED=1'
        $run.Stderr | Should -Not -Match 'UNVERIFIED CODE WILL RUN'
    }

    It 'names the variable that carries the digest being asked for' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $run = Invoke-VerifyCase -Digest empty -VarName E_RETRY_SHA -Label automation/yuruna-retry.sh
        $run.Rc | Should -Be 1
        $run.Stderr | Should -Match 'E_RETRY_SHA=<64 hex digits>'
        $run.Stderr | Should -Not -Match 'E_SHA='
    }

    It 'lets an empty digest through only under EXEC_ALLOW_UNVERIFIED=1, and says so on stderr' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $run = Invoke-VerifyCase -Digest empty -Setup 'export EXEC_ALLOW_UNVERIFIED=1'
        $run.Rc | Should -Be 0
        $run.Stdout | Should -Not -Match 'UNVERIFIED' -Because 'the banner belongs to the operator, not to anything that captures stdout'
        $banner = @($run.Stderr -split '\r?\n' | Where-Object { $_ -match '^!!' })
        $banner.Count | Should -BeGreaterOrEqual 6 -Because 'a one-line warning is easy to scroll past; the override must be conspicuous'
        $run.Stderr | Should -Match 'UNVERIFIED CODE WILL RUN'
        $run.Stderr | Should -Match 'file:\s+guest/example\.sh'
        $run.Stderr | Should -Match 'NOT checked'
    }

    It 'honors the override only when it is exactly 1' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        foreach ($value in 'true', 'yes', '0', 'on') {
            $run = Invoke-VerifyCase -Digest empty -Setup "export EXEC_ALLOW_UNVERIFIED=$value"
            $run.Rc | Should -Be 1 -Because "EXEC_ALLOW_UNVERIFIED=$value is not the deliberate spelling"
            $run.Stderr | Should -Match 'only the value 1 enables it'
        }
        $blank = Invoke-VerifyCase -Digest empty -Setup 'export EXEC_ALLOW_UNVERIFIED='
        $blank.Rc | Should -Be 1
    }

    It 'never lets the override excuse a wrong digest' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $run = Invoke-VerifyCase -Digest wrong -Setup 'export EXEC_ALLOW_UNVERIFIED=1'
        $run.Rc | Should -Be 1
        $run.Stderr | Should -Match 'INTEGRITY MISMATCH'
        $run.Stderr | Should -Match 'never excuses a wrong one'
        $run.Stderr | Should -Not -Match 'UNVERIFIED CODE WILL RUN'
    }

    It 'keeps EXEC_REQUIRE_SHA256=1 strict, with or without the override' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $alone = Invoke-VerifyCase -Digest empty -Setup 'export EXEC_REQUIRE_SHA256=1'
        $alone.Rc | Should -Be 1
        $alone.Stderr | Should -Match 'host requires a digest'
        $alone.Stderr | Should -Not -Match 'EXEC_ALLOW_UNVERIFIED'
        $both = Invoke-VerifyCase -Digest empty -Setup 'export EXEC_REQUIRE_SHA256=1', 'export EXEC_ALLOW_UNVERIFIED=1'
        $both.Rc | Should -Be 1
        $both.Stderr | Should -Match 'host requires a digest'
        $both.Stderr | Should -Match 'does not apply while EXEC_REQUIRE_SHA256=1'
        $both.Stderr | Should -Not -Match 'UNVERIFIED CODE WILL RUN'
    }

    It 'names where the unverified bytes come from, GitHub fallback included' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $ref = '0123456789abcdef0123456789abcdef01234567'
        $github = Invoke-VerifyCase -Digest empty -Setup 'export EXEC_ALLOW_UNVERIFIED=1', 'FETCH_SOURCE=github', 'GH_REPO=owner/repo', "GH_REF=$ref"
        $github.Rc | Should -Be 0
        $github.Stderr | Should -Match "source:\s+GitHub owner/repo at $ref"
        $served = Invoke-VerifyCase -Digest empty -Setup 'export EXEC_ALLOW_UNVERIFIED=1', 'FETCH_SOURCE=host', 'HOST_BASE=http://192.0.2.7:8080/yuruna-repo/'
        $served.Rc | Should -Be 0
        $served.Stderr | Should -Match 'source:\s+http://192\.0\.2\.7:8080/yuruna-repo/'
    }
}

Describe 'fetch-and-execute.sh digest default (whole script, stubbed network)' {
    # verify_sha256 returning 1 proves nothing unless the script then stops: the
    # promise is that an undigested payload does not RUN, and the exit status the
    # host reads is the script's, not the function's. So the real script is run
    # end to end, with the network, the terminal and sudo stubbed and the two
    # system paths it writes (the retry library directory and the run log)
    # pointed at a scratch directory. Everything is built inside bash so no
    # Windows/POSIX path has to be translated, and every scenario runs once in
    # BeforeAll so the cases below only read results.
    BeforeAll {
        $script:faeRuns = $null
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        $modern = $false
        if ($bash) { $modern = [int](& $bash.Source -c 'echo ${BASH_VERSINFO[0]}') -ge 4 }
        $guestShaped = Test-Path -LiteralPath '/etc/yuruna/host.env'
        if ($bash -and $modern) {
            $text = (Get-Content -Raw -LiteralPath $script:faePath).Replace("`r`n", "`n")
            $libDecl = 'YURUNA_LIB_DIR=/usr/local/lib/yuruna'
            $logDecl = "fae_log='/tmp/yuruna-last-fetch-and-execute.log'"
            # A silent miss here would let a run write to the real system paths.
            if (-not $text.Contains($libDecl) -or -not $text.Contains($logDecl)) {
                throw 'fetch-and-execute.sh no longer declares the two system paths this harness redirects; update the harness before running it.'
            }
            $text = $text.Replace($libDecl, 'YURUNA_LIB_DIR="${FAE_TEST_LIB_DIR:?}"').Replace($logDecl, 'fae_log="${FAE_TEST_LOG:?}"')

            $githubScenarios = if ($guestShaped) { '' } else { @'
scenario github_no_digest present $gh_repo $gh_ref
scenario github_override present $gh_repo $gh_ref EXEC_ALLOW_UNVERIFIED=1
'@ }
            $template = @'
unset E_SHA EXEC_SHA256 E_RETRY_SHA EXEC_RETRY_SHA256 EXEC_REQUIRE_SHA256 EXEC_ALLOW_UNVERIFIED \
      E_FB_REPO E_FB_REF EXEC_FALLBACK_REPO EXEC_FALLBACK_REF YURUNA_GITHUB_REPO YURUNA_GITHUB_REF \
      EXEC_BASE_URL EXEC_QUERY_PARAMS YurunaCacheContent GH_TOKEN E_SI E_QI \
      YURUNA_STATUS_SERVICE_IP YURUNA_STATUS_SERVICE_PORT
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/lib"
cat > "$work/bin/wget" <<'STUB'
#!/bin/bash
out=''
while [ $# -gt 0 ]; do
    case "$1" in -qO|-O) out="$2"; shift ;; esac
    shift
done
echo wget >> "$FAE_TEST_CALLS"
if [ -n "$out" ] && [ "$out" != /dev/null ]; then
    case "$out" in
        *retrylib*) cat "$FAE_TEST_LIBBODY" > "$out" ;;
        *)          cat "$FAE_TEST_PAYLOAD" > "$out" ;;
    esac
fi
exit 0
STUB
printf '#!/bin/bash\nexit 0\n' > "$work/bin/clear"
printf '#!/bin/bash\nexec "$@"\n' > "$work/bin/sudo"
chmod +x "$work/bin/wget" "$work/bin/clear" "$work/bin/sudo"
cat > "$work/payload.sh" <<'PAYLOAD'
echo "PAYLOAD_RAN"
echo "OVERRIDE_SEEN=${EXEC_ALLOW_UNVERIFIED-unset}"
PAYLOAD
printf '# retry library fixture\n' > "$work/libbody"
good=$( (sha256sum "$work/payload.sh" 2>/dev/null || shasum -a 256 "$work/payload.sh") | awk '{print $1}')
libgood=$( (sha256sum "$work/libbody" 2>/dev/null || shasum -a 256 "$work/libbody") | awk '{print $1}')
cat > "$work/fae.sh" <<'FAE_SCRIPT_END'
__FAE__
FAE_SCRIPT_END

scenario() {   # scenario <name> <present|absent> [VAR=value ...]
    local name="$1" lib="$2" rc=0 calls lib_bytes=0
    shift 2
    : > "$work/calls"
    rm -f "$work/lib/yuruna-retry.sh" "$work/fae.log"
    if [ "$lib" = present ]; then : > "$work/lib/yuruna-retry.sh"; fi
    env PATH="$work/bin:$PATH" EXEC_PROFILE=0 \
        FAE_TEST_LIB_DIR="$work/lib" FAE_TEST_LOG="$work/fae.log" FAE_TEST_CALLS="$work/calls" \
        FAE_TEST_PAYLOAD="$work/payload.sh" FAE_TEST_LIBBODY="$work/libbody" \
        "$@" bash "$work/fae.sh" guest/payload.sh </dev/null >"$work/out" 2>"$work/err" || rc=$?
    calls=$(wc -l < "$work/calls" | tr -d ' ')
    if [ -f "$work/lib/yuruna-retry.sh" ]; then lib_bytes=$(wc -c < "$work/lib/yuruna-retry.sh" | tr -d ' '); fi
    echo "@@SCENARIO $name"
    echo "RC=$rc"
    echo "WGET_CALLS=$calls"
    echo "LIB_BYTES=$lib_bytes"
    echo '@@STDOUT'; cat "$work/out"; echo
    echo '@@STDERR'; cat "$work/err"; echo
    echo '@@LOG'; cat "$work/fae.log" 2>/dev/null; echo
    echo '@@END'
}

host=EXEC_BASE_URL=http://stub.invalid/yuruna-repo/
gh_repo=E_FB_REPO=owner/repo
gh_ref=E_FB_REF=0123456789abcdef0123456789abcdef01234567

scenario no_digest present $host
scenario override present $host EXEC_ALLOW_UNVERIFIED=1
scenario wrong_digest_override present $host EXEC_ALLOW_UNVERIFIED=1 E_SHA=deadbeef
scenario require_override present $host EXEC_REQUIRE_SHA256=1 EXEC_ALLOW_UNVERIFIED=1
scenario verified present $host E_SHA="$good"
scenario verified_override present $host E_SHA="$good" EXEC_ALLOW_UNVERIFIED=1
scenario lib_no_digest absent $host E_SHA="$good"
scenario lib_verified absent $host E_SHA="$good" E_RETRY_SHA="$libgood"
__GITHUB__
'@
            $driver = $template.Replace('__GITHUB__', $githubScenarios).Replace('__FAE__', $text)
            $out = (Invoke-BashDriver -BashPath $bash.Source -Script $driver).Output
            $records = @{}
            $pattern = '(?s)@@SCENARIO (\S+)\r?\nRC=(\d+)\r?\nWGET_CALLS=(\d+)\r?\nLIB_BYTES=(\d+)\r?\n@@STDOUT\r?\n(.*?)\r?\n@@STDERR\r?\n(.*?)\r?\n@@LOG\r?\n(.*?)\r?\n@@END'
            foreach ($m in [regex]::Matches($out, $pattern)) {
                $records[$m.Groups[1].Value] = [pscustomobject]@{
                    Rc = [int]$m.Groups[2].Value; Wget = [int]$m.Groups[3].Value; LibBytes = [int]$m.Groups[4].Value
                    Stdout = $m.Groups[5].Value; Stderr = $m.Groups[6].Value; Log = $m.Groups[7].Value
                }
            }
            $script:faeRuns = $records
            $script:faeRawOutput = $out
        }
        $script:faeSkipReason = if (-not $bash) { 'bash is not available on this host' } elseif (-not $modern) { 'the host bash predates 4.0; the script targets a Linux guest' } else { '' }
        $script:faeGuestShaped = $guestShaped
    }

    It 'ran every scenario the cases below read' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        $expected = @('no_digest', 'override', 'wrong_digest_override', 'require_override', 'verified', 'verified_override', 'lib_no_digest', 'lib_verified')
        if (-not $script:faeGuestShaped) { $expected += 'github_no_digest', 'github_override' }
        foreach ($name in $expected) {
            Assert-True $script:faeRuns.ContainsKey($name) "scenario '$name' produced a result block; raw output:`n$($script:faeRawOutput)"
        }
    }

    It 'refuses to run a payload it has no digest for, exits non-zero, and says how to supply one' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        $run = $script:faeRuns['no_digest']
        $run.Rc | Should -Be 3
        $run.Stdout | Should -Not -Match 'PAYLOAD_RAN'
        $run.Stdout | Should -Match 'NONZERO SCRIPT EXIT:'
        $run.Stdout | Should -Match '\(no expected digest -- refusing to run\)'
        $run.Stdout | Should -Not -Match 'FETCHED AND EXECUTED'
        $run.Stderr | Should -Match 'NO EXPECTED DIGEST'
        $run.Stderr | Should -Match 'E_SHA=<64 hex digits>'
        $run.Stderr | Should -Match 'EXEC_ALLOW_UNVERIFIED=1'
    }

    It 'runs it under EXEC_ALLOW_UNVERIFIED=1 behind a banner naming the file, and records that in the log' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        $run = $script:faeRuns['override']
        $run.Rc | Should -Be 0
        $run.Stdout | Should -Match 'PAYLOAD_RAN'
        $run.Stdout | Should -Match 'FETCHED AND EXECUTED'
        $run.Stderr | Should -Match 'UNVERIFIED CODE WILL RUN'
        $run.Stderr | Should -Match 'file:\s+guest/payload\.sh'
        $run.Stderr | Should -Match 'NOT checked'
        @($run.Stderr -split '\r?\n' | Where-Object { $_ -match '^!!' }).Count | Should -BeGreaterOrEqual 6
        $run.Log | Should -Match '# integrity: UNVERIFIED'
    }

    It 'does not hand the waiver on to the payload it was granted for' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        $script:faeRuns['override'].Stdout | Should -Match 'OVERRIDE_SEEN=unset'
    }

    It 'fails on a wrong digest even with the override, and never runs the payload' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        $run = $script:faeRuns['wrong_digest_override']
        $run.Rc | Should -Be 3
        $run.Stdout | Should -Not -Match 'PAYLOAD_RAN'
        $run.Stdout | Should -Match '\(integrity mismatch -- refusing to run\)'
        $run.Stderr | Should -Match 'INTEGRITY MISMATCH'
        $run.Stderr | Should -Not -Match 'UNVERIFIED CODE WILL RUN'
    }

    It 'keeps EXEC_REQUIRE_SHA256=1 strict: the override does not bypass it' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        $run = $script:faeRuns['require_override']
        $run.Rc | Should -Be 3
        $run.Stdout | Should -Not -Match 'PAYLOAD_RAN'
        $run.Stderr | Should -Match 'host requires a digest'
        $run.Stderr | Should -Match 'does not apply while EXEC_REQUIRE_SHA256=1'
        $run.Stderr | Should -Not -Match 'UNVERIFIED CODE WILL RUN'
    }

    It 'runs a verified payload without a banner, whether or not the override is also set' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        foreach ($name in 'verified', 'verified_override') {
            $run = $script:faeRuns[$name]
            $run.Rc | Should -Be 0 -Because $name
            $run.Stdout | Should -Match 'sha256 verified \(guest/payload\.sh\)'
            $run.Stdout | Should -Match 'PAYLOAD_RAN'
            $run.Stderr | Should -Not -Match 'UNVERIFIED' -Because $name
            $run.Log | Should -Not -Match '# integrity: UNVERIFIED' -Because $name
        }
    }

    It 'applies the same rule on the GitHub fallback and names its repository and commit' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        if ($script:faeGuestShaped) { Set-ItResult -Skipped -Because 'this host is guest-shaped (/etc/yuruna/host.env present)'; return }
        $refused = $script:faeRuns['github_no_digest']
        $refused.Rc | Should -Be 3
        $refused.Stdout | Should -Match 'source: github'
        $refused.Stdout | Should -Not -Match 'PAYLOAD_RAN'
        $refused.Stderr | Should -Match 'NO EXPECTED DIGEST'
        $waived = $script:faeRuns['github_override']
        $waived.Rc | Should -Be 0
        $waived.Stdout | Should -Match 'PAYLOAD_RAN'
        $waived.Stderr | Should -Match 'source:\s+GitHub owner/repo at 0123456789abcdef0123456789abcdef01234567'
    }

    It 'holds the retry library to the same rule, without stopping the payload' {
        if ($script:faeSkipReason) { Set-ItResult -Skipped -Because $script:faeSkipReason; return }
        $withheld = $script:faeRuns['lib_no_digest']
        $withheld.Rc | Should -Be 0
        $withheld.Stdout | Should -Match 'PAYLOAD_RAN'
        $withheld.LibBytes | Should -Be 0 -Because 'a library nobody vouched for is not installed'
        $withheld.Stderr | Should -Match 'E_RETRY_SHA=<64 hex digits>'
        $installed = $script:faeRuns['lib_verified']
        $installed.Rc | Should -Be 0
        $installed.LibBytes | Should -BeGreaterThan 0 -Because 'a verified library is installed'
        $installed.Stdout | Should -Match 'sha256 verified \(automation/yuruna-retry\.sh\)'
    }
}

Describe 'envelope name compatibility (guest side)' {
    # The host types the short names, but a short-name guest can still meet an
    # older host that types EXEC_*, and a hand-run guest has only the host.env
    # values. All three levels must resolve, newest first, or the pairing breaks
    # on a name mismatch rather than on anything real. (The opposite direction --
    # an old guest under a new host -- is what the unshortened
    # EXEC_REQUIRE_SHA256 above keeps fail-closed.)
    It 'resolves E_FB_REPO/REF first, then EXEC_FALLBACK_*, then host.env' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        # resolve_fetch_source sources /etc/yuruna/host.env when present, which
        # would supply its own YURUNA_GITHUB_* and mask the third level. That
        # file is a guest artifact; a machine that has one is not a test host.
        if (Test-Path -LiteralPath '/etc/yuruna/host.env') { Set-ItResult -Skipped -Because 'this host is guest-shaped (/etc/yuruna/host.env present)'; return }
        $fae = Get-Content -Raw -LiteralPath $script:faePath
        $fn  = [regex]::Match($fae, '(?ms)^resolve_fetch_source\(\)\s*\{.*?^\}')
        Assert-True $fn.Success 'resolve_fetch_source found in fetch-and-execute.sh'
        $driver = @'

E_FB_REPO=short/repo; EXEC_FALLBACK_REPO=legacy/repo; YURUNA_GITHUB_REPO=baked/repo
E_FB_REF=aaa;         EXEC_FALLBACK_REF=bbb;          YURUNA_GITHUB_REF=ccc
resolve_fetch_source; printf '%s:%s ' "$GH_REPO" "$GH_REF"
unset E_FB_REPO E_FB_REF
resolve_fetch_source; printf '%s:%s ' "$GH_REPO" "$GH_REF"
unset EXEC_FALLBACK_REPO EXEC_FALLBACK_REF
resolve_fetch_source; printf '%s:%s\n' "$GH_REPO" "$GH_REF"
'@
        $script = $fn.Value + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        Assert-StringEqual -Actual $out -Expected 'short/repo:aaa legacy/repo:bbb baked/repo:ccc' -Because "fallback name precedence, got '$out'"
    }

    # The two digests are read at file scope, not inside an extractable
    # function, so these are asserted against the source.
    It 'reads both digest spellings, short name first' {
        $fae = Get-Content -Raw -LiteralPath $script:faePath
        Assert-True ($fae -match '\$\{E_SHA:-\$\{EXEC_SHA256:-\}\}')             'payload digest accepts both spellings'
        Assert-True ($fae -match '\$\{E_RETRY_SHA:-\$\{EXEC_RETRY_SHA256:-\}\}') 'retry-lib digest accepts both spellings'
    }
}

Describe 'guidance when the GitHub fallback cannot work' {

    # A guest cannot tell whether its host's git credential may read the project,
    # so when the fallback is the only route left and that route can only 404, the
    # banners name where the answer already lives instead of guessing. Printed at
    # file scope rather than from an extractable function, so asserted against the
    # source the way the digest reads above are.
    It 'sends the reader to the pool column and to the standalone check' {
        $fae = Get-Content -Raw -LiteralPath $script:faePath
        Assert-True ($fae -match "'Project'")        'the pool column carrying the verdict is named'
        Assert-True ($fae -match 'DENIED')           'the verdict no retry can fix is named'
        Assert-True ($fae -match 'Test-Config\.ps1') 'the standalone host check is named'
    }

    # Guidance that names a page is only as good as the page. Tying the two
    # together here means renaming the column breaks this test rather than
    # quietly leaving every stranded guest pointed at something that is gone.
    It 'names a column that Pool Control actually renders, and a script that exists' {
        $repo = Split-Path -Parent (Split-Path -Parent $script:faePath)
        $hostsPage = Join-Path $repo 'test/extension/pool-control-service/server/internal/httpsrv/web/hosts.html'
        Assert-True (Test-Path -LiteralPath $hostsPage) "pool control hosts page present at $hostsPage"
        Assert-True ((Get-Content -Raw -LiteralPath $hostsPage) -match '>Project</button>') `
            'the hosts page still renders the Project column the guest banner names'
        Assert-True (Test-Path -LiteralPath (Join-Path $repo 'test/Test-Config.ps1')) `
            'the standalone check the banner names still exists'
    }
}
