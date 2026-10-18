<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42dc2c8b-375c-4869-8113-cd1b1b7a0e53
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test gui transport integrity pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Verifies bounded fetch preparation on every GUI host with local shells and mocked host I/O.
#>

BeforeDiscovery {
    $script:localShellAvailable = $false
    $script:contextShellAvailable = $false
    if (Get-Command bash -CommandType Application -ErrorAction SilentlyContinue) {
        try {
            & bash -c 'command -v sha256sum >/dev/null 2>&1' 2>$null
            $script:localShellAvailable = $LASTEXITCODE -eq 0
            & bash -c 'declare -A probe && command -v gzip >/dev/null 2>&1' 2>$null
            $script:contextShellAvailable = $LASTEXITCODE -eq 0
        } catch { $script:localShellAvailable = $false }
    }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
    $source = Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1'
    $tokens = $null; $errors = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    function Get-FunctionSource([string]$Name) {
        $script:ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true).Extent.Text
    }
    $script:NonzeroScriptExitSentinel = 'NONZERO SCRIPT EXIT:'
    . ([scriptblock]::Create((Get-FunctionSource 'Get-GuiFetchExecutionInput')))
    . ([scriptblock]::Create((Get-FunctionSource 'Get-FetchExecutionCommand')))
    . ([scriptblock]::Create((Get-FunctionSource 'Get-FetchExecutionContext')))
    . ([scriptblock]::Create((Get-FunctionSource 'Get-GuiFetchEnvelopeInput')))
    . ([scriptblock]::Create((Get-FunctionSource 'Test-GuiFetchInputStalled')))
    . ([scriptblock]::Create((Get-FunctionSource 'Get-GuiFetchPayloadState')))
    . ([scriptblock]::Create((Get-FunctionSource 'Get-GuiFetchEnvelopeTransfer')))
    # The console tail of a launcher that refused a doubled character: the
    # continuation prompts are still on screen, and OCR read the returning
    # prompt's dollar sign as S.
    $script:RefusedEnvelopeOcrTail = "a1 Te2+ROHCS`nN4XNEHPOIRVNi8Cjs82 `"5`n> __y+s 'Rowt4VHTiKaQFXmybG72 1RoSK4URAbZoRJSPHGGTF 4nmiOdg 7B ROZTkHY4CVS3SEF +40 j8GCOfB2+0 jhcbuOf vNKHNP TUxykh6BV+/RF 1DcCOVdpob+4RadErSsMd9ZHrHSEBOthK IhyT iySADaF qONEGaYRSgyvkoewoZhUFHOTZ4B9pW TK gKEyZBMReSoEpmaMsoMBedZvk-+NbVEZr-zhmbZU7RVXtaLHf TL`n> __uss 'FATYSMHF2F vumS LR IF 7k3bk TPOX194012Rh2MSeLoKerUd6CC iPHtcBVPcUESMBk VD LbyL Tbk T1vU@ShXXSN60qV2tXeJErOF LOYKBOCE.i IRPUxPSbHOJEd Ts THNxpy JNERBVVx+eL 201 TLHYx LobseCcRZAuvratHCU4Hy ipFog3MLHAIN/uZUSS 7uspsaSXXkt+VS2 iakkXo+hlaz9o65 l8zkbaczdJ102qTX`n> uss 'UA4G27NGSSCHSx+jSANEHZExRE/ luh2/F THHDYULIT7GK/MmAF OtL Yeaq iHKMBBURK YASXONACINE1 LOSsoacZSOACRNUCOF +xOxVF ik Jx@XHE jz jcdXSrE JbuF uj VuBg INtCVHH# 30 TibVFCNWVIL VPhUd+BQGGBankMOJSqircM4banuB6rBrur iPMFF IHaE7S2y09j40 jhfsc/2+usppeWsSwvrunGoPeaGyx`nJ5`n> __y+='7/du30B0a75ZuNaxgpBuVR10SH22/RPOUKAF Ksargk JBZ3r`u{00A5}g2P TOCOHuGN+h9X7LO531bzh/TaRaL +c/6Ipsf xv jSq0+inc 7127542 j VSBtekatxMr2d`u{00E9}901PrZhxFSSbS1 Thut /ABE+xVEOBAAA 5`n> Ufe --gui 480fSabdce1asees2996d3226263937ae9d7014eb94205f alebGac7oaseessds `"S__y`"`nbase`u{00E9}4: error: invalid inpu`ngzip: stdin: unexpected end of file`nNONZERO SCRIPT EXIT: YFE_GUI_ENCODING`nyUUser2`u{00E9}@yuhost26:`u{201C}S"
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.GitHubSource.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.OcrMatch.psm1') -Force
    $script:payload = '/usr/local/lib/yuruna/fetch-and-execute.sh project/example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh'
    $fixtureRoot = Join-Path $TestDrive 'gui-fetch'
    $file = Join-Path $fixtureRoot 'project/example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh'
    $retry = Join-Path $fixtureRoot 'automation/yuruna-retry.sh'
    $null = New-Item -ItemType Directory -Path (Split-Path $file), (Split-Path $retry) -Force
    [IO.File]::WriteAllText($file, "printf '%s' 'fixture workload'`n", [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../automation/yuruna-retry.sh') -Destination $retry
    function Get-CycleGuestDataFolder { param($VMName) $null = $VMName; Join-Path $TestDrive 'cycle/vm' }
    $script:context = @{Step=@{};RepoRoot=$fixtureRoot;VMName='vm';StepInvocationId='9dd7e79e0e404f0b8aa334f1337540e9';SequenceInvocationId='2ba53dd6961e4beea8ec17e8416f8651'}
    $script:uncompressedContext = Get-FetchExecutionContext -Context $script:context -CommandLine $script:payload -WarningAction SilentlyContinue
    $script:fetchContext = Get-FetchExecutionContext -Context $script:context -CommandLine $script:payload -Compress -WarningAction SilentlyContinue
    $script:realisticCommand = $script:fetchContext.Command
    function Invoke-LocalInput([string[]]$Lines) {
        $priorEncoding = [Console]::OutputEncoding
        $driverPath = [IO.Path]::GetTempFileName()
        try {
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            # Bash heredoc delimiters must use the same LF endings as the
            # embedded launcher. A file also avoids native command-line limits.
            $driver = ($Lines -join "`n").Replace("`r`n", "`n")
            [IO.File]::WriteAllText($driverPath, $driver, [Text.UTF8Encoding]::new($false))
            $launch = @'
driver=$1
if command -v wslpath >/dev/null 2>&1; then
    driver=$(wslpath -u "$driver") || exit 125
elif command -v cygpath >/dev/null 2>&1; then
    driver=$(cygpath -u "$driver") || exit 125
fi
exec bash "$driver"
'@
            $result = & bash -c $launch.Replace("`r`n", "`n") 'yuruna-gui-fixture' $driverPath 2>&1
            $script:localExitCode = $LASTEXITCODE
        } finally {
            [Console]::OutputEncoding = $priorEncoding
            Remove-Item -LiteralPath $driverPath -Force -ErrorAction SilentlyContinue
        }
        return ($result -join "`n")
    }
    $launcher = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../automation/yuruna-fetch-context.sh'))
    $launcher = $launcher.Replace('local dir="$HOME/.local/state/yuruna/fetch-context"', 'local dir="$YURUNA_CONTEXT_TEST_DIRECTORY/state"')
    $launcher = $launcher.Replace('local dir="$HOME/.local/state/yuruna/gui-rejection"', 'local dir="$YURUNA_CONTEXT_TEST_DIRECTORY/rejection"')
    # Let the guest shell create its own scratch files. A Windows host's
    # TestDrive path need not be readable by a WSL or MSYS bash executable.
    $script:launcherDriver = @'
yuruna_context_test_directory=$(mktemp -d)
export YURUNA_CONTEXT_TEST_DIRECTORY="$yuruna_context_test_directory"
trap 'rm -rf -- "$yuruna_context_test_directory"' EXIT
cat > "$yuruna_context_test_directory/launcher.sh" <<'YURUNA_CONTEXT_TEST_SCRIPT'
'@ + "`n" + $launcher + "`nYURUNA_CONTEXT_TEST_SCRIPT`n" + @'
yfe() { bash "$yuruna_context_test_directory/launcher.sh" "$@"; }
'@
}

Describe 'Bounded GUI command staging' {
    It 'compresses GUI metadata enough to reduce physical lines while preserving every binding' {
        $script:fetchContext.Preparation | Should -Match 'gzip -dc'
        $script:fetchContext.Command.Length | Should -BeLessThan $script:uncompressedContext.Command.Length
        @(Get-GuiFetchExecutionInput -CommandLine $script:fetchContext.Command).Count |
            Should -BeLessThan @(Get-GuiFetchExecutionInput -CommandLine $script:uncompressedContext.Command).Count
        foreach ($key in $script:fetchContext.Fields.Keys | Where-Object { $_ -ne 'id' }) {
            $script:fetchContext.Fields[$key] | Should -BeExactly $script:uncompressedContext.Fields[$key]
        }
    }

    It 'keeps the original preparation when compression would increase console input' {
        $context = @{Step=@{}}
        $plain = Get-FetchExecutionContext -Context $context -CommandLine 'true'
        $compact = Get-FetchExecutionContext -Context $context -CommandLine 'true' -Compress
        $compact.Preparation | Should -Not -Match 'gzip -dc'
        $compact.Preparation.Length | Should -Be $plain.Preparation.Length
    }

    It 'keeps a short command unchanged' {
        @(Get-GuiFetchExecutionInput -CommandLine 'echo ready') | Should -HaveCount 1
        Get-GuiFetchExecutionInput -CommandLine 'echo ready' | Should -BeExactly 'echo ready'
    }

    It 'stages preparation while keeping the launch prefix at 16 characters' {
        $script:payload.Length | Should -Be 129
        $script:fetchContext.Prefix.Length | Should -Be 16
        $script:fetchContext.Launch.Length | Should -Be 155
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $script:realisticCommand)
        $lines.Count | Should -BeGreaterThan 3
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 400 }
        foreach ($line in $lines[0..($lines.Count - 2)]) { $line.Length | Should -BeLessOrEqual 240 }
        $lines[-1] | Should -Match 'sha256sum'
        $lines[-1] | Should -Not -Match 'NONZERO SCRIPT EXIT:'
    }

    It 'keeps every echoed input and the combined echo outside the real fuzzy failure matcher' {
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $script:realisticCommand)
        foreach ($line in $lines) { Test-OCRMatch -Text $line -Pattern 'NONZERO SCRIPT EXIT:' | Should -BeFalse }
        Test-OCRMatch -Text ($lines -join "`n") -Pattern 'NONZERO SCRIPT EXIT:' | Should -BeFalse
    }

    It 'uses the real integrity builder and preserves its hashes and enforced flag' {
        function Get-YurunaGitHubSource { return @{Repo='alissonsol/yurunadev';Ref='933b9d5b0beedd9a5b36a33306093242f87b63f3'} }
        function Test-YurunaFileMatchesHead { return $true }
        $relative = 'project/example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh'
        $file = Join-Path $TestDrive $relative
        $retry = Join-Path $TestDrive 'automation/yuruna-retry.sh'
        $null = New-Item -ItemType Directory -Path (Split-Path $file), (Split-Path $retry) -Force
        [IO.File]::WriteAllText($file, '# test payload')
        [IO.File]::WriteAllText($retry, '# test retry library')
        $context = @{Step=@{};RepoRoot=$TestDrive;StepInvocationId='step';SequenceInvocationId='sequence'}
        $result = Get-FetchExecutionContext -Context $context -CommandLine $script:payload
        $result.Fields.EXEC_REQUIRE_SHA256 | Should -BeExactly '1'
        $result.Fields.E_SHA | Should -BeExactly (Get-FileHash $file).Hash.ToLowerInvariant()
        $result.Fields.E_RETRY_SHA | Should -BeExactly (Get-FileHash $retry).Hash.ToLowerInvariant()
        $result.Launch.Length | Should -Be 155
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $result.Command)
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 400 }
    }

    It 'counts escaped apostrophes against every physical input line' {
        $command = ": " + ("''" * 250)
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 400 }
        foreach ($line in $lines[0..($lines.Count - 2)]) { $line.Length | Should -BeLessOrEqual 240 }
    }
}

Describe 'GUI command staging in a local bash with sha256sum' -Skip:(-not $script:localShellAvailable) {
    It 'runs compressed context preparation and the seeded launcher with exact Unicode and environment values' -Skip:(-not $script:contextShellAvailable) {
        $command = "printf '%s|' `"it's caf$([char]0x00e9)`"; printf '%s' `"`$E_SI`""
        $context = Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $context.Preparation | Should -Match 'gzip -dc'
        $lines = @($script:launcherDriver) + @(Get-GuiFetchExecutionInput -CommandLine $context.Command)
        Invoke-LocalInput $lines | Should -BeExactly ("it's caf$([char]0x00e9)|" + $script:context.StepInvocationId)
        $script:localExitCode | Should -Be 0
        # A consumed context cannot be replayed even when the compressed bytes
        # are correct and the caller knows the original launch command.
        $output = Invoke-LocalInput ($lines + @("printf '\n'", $context.Launch))
        $output | Should -Match 'YFE_CONTEXT_MISSING'
        $script:localExitCode | Should -Be 125
    }

    It 'refuses a changed decompressed digest before running the payload' -Skip:(-not $script:contextShellAvailable) {
        $context = Get-FetchExecutionContext -Context $script:context -CommandLine 'echo EXECUTED' -Compress
        $changed = [regex]::Replace($context.Command, '(?<=--prepare [0-9a-f]{11} [0-9]+ )[0-9a-f]{64}', ('0' * 64))
        $changed | Should -Not -BeExactly $context.Command
        $output = Invoke-LocalInput (@($script:launcherDriver) + @(Get-GuiFetchExecutionInput -CommandLine $changed))
        $output | Should -Match 'YFE_CONTEXT_DIGEST'
        $output | Should -Match 'NONZERO SCRIPT EXIT:'
        $output | Should -Not -Match 'EXECUTED'
        $script:localExitCode | Should -Be 125
    }

    It 'refuses corrupt compression and a failing decompressor before running the payload' -Skip:(-not $script:contextShellAvailable) {
        foreach ($brokenDecompressor in @($false, $true)) {
            $context = Get-FetchExecutionContext -Context $script:context -CommandLine 'echo EXECUTED' -Compress
            $context.Preparation | Should -Match 'gzip -dc'
            $command = if ($brokenDecompressor) { $context.Command } else {
                [regex]::Replace($context.Command, "(?<=printf '%s' ')[A-Za-z0-9+/=]+", 'AAAA')
            }
            $driver = @($script:launcherDriver)
            if ($brokenDecompressor) { $driver += 'gzip() { return 127; }' }
            $output = Invoke-LocalInput ($driver + @(Get-GuiFetchExecutionInput -CommandLine $command))
            $output | Should -Match 'NONZERO SCRIPT EXIT:'
            $output | Should -Not -Match 'EXECUTED'
            $script:localExitCode | Should -Be 125
        }
    }

    It 'rejects gzip CRC and truncated-footer failures after the original metadata was emitted' -Skip:(-not $script:contextShellAvailable) {
        foreach ($failure in 'crc', 'footer') {
            $context = Get-FetchExecutionContext -Context $script:context -CommandLine 'echo EXECUTED' -Compress
            $encoded = [regex]::Match($context.Preparation, "(?<=printf '%s' ')[A-Za-z0-9+/=]+").Value
            $encoded | Should -Not -BeNullOrEmpty
            $bytes = [Convert]::FromBase64String($encoded)
            if ($failure -eq 'crc') {
                $bytes[$bytes.Length - 8] = $bytes[$bytes.Length - 8] -bxor 1
            } else {
                $bytes = $bytes[0..($bytes.Length - 5)]
            }
            $damaged = [Convert]::ToBase64String($bytes)
            $command = $context.Command.Replace($encoded, $damaged)
            $output = Invoke-LocalInput (@($script:launcherDriver) + @(Get-GuiFetchExecutionInput -CommandLine $command))
            $output | Should -Match 'gzip:'
            $output | Should -Match 'NONZERO SCRIPT EXIT:'
            $output | Should -Not -Match 'EXECUTED|YFE_CONTEXT_SIZE|YFE_CONTEXT_DIGEST'
            $script:localExitCode | Should -Be 125
        }
    }

    It 'executes once when any single inter-line Enter is lost, including before the guard' {
        $command = "printf '%s\n' executed; : '" + ('x' * 500) + "'"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        for ($boundary = 0; $boundary -lt $lines.Count - 1; $boundary++) {
            $delivered = @()
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($index -eq $boundary) {
                    $delivered += $lines[$index] + $lines[$index + 1]
                    $index++
                } else { $delivered += $lines[$index] }
            }
            Invoke-LocalInput $delivered | Should -BeExactly 'executed'
            $script:localExitCode | Should -Be 0
        }
    }

    It 'tolerates missing or duplicated inter-line Enters without changing compound commands' {
        $command = "printf '%s\n' `"it's literal`"; : '" + ('x' * 500) + "'; printf '%s\n' second; exit 17"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        foreach ($separator in @('', "`n`n")) {
            Invoke-LocalInput @(($lines -join $separator)) | Should -BeExactly "it's literal`nsecond"
            $script:localExitCode | Should -Be 17
        }
    }

    It 'still rejects a corrupted chunk when the Enter before the guard is lost' {
        $command = "printf '%s\n' EXECUTED; : '" + ('x' * 500) + "'"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        $lines[1] = $lines[1].Replace('x', 'z')
        $delivered = @($lines[0..($lines.Count - 3)]) + @($lines[-2] + $lines[-1])
        Invoke-LocalInput $delivered | Should -BeExactly 'NONZERO SCRIPT EXIT: GUI command integrity mismatch'
        $script:localExitCode | Should -Be 125
    }

    It 'reconstructs the complete workload command without executing it' {
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $script:realisticCommand)
        # Inspect the verified command without running a workload or contacting
        # a host. The actual digest and reconstruction execute unchanged.
        $lines[-1] = $lines[-1].Replace('eval "$__y"', 'printf %s "$__y"')
        Invoke-LocalInput $lines | Should -BeExactly $script:realisticCommand
        $script:localExitCode | Should -Be 0
    }

    It 'emits a failure that the real fuzzy OCR matcher recognizes after corruption' {
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $script:realisticCommand)
        $lines[1] = $lines[1].Insert($lines[1].Length - 2, 'x')
        $output = Invoke-LocalInput $lines
        Test-OCRMatch -Text $output -Pattern 'NONZERO SCRIPT EXIT:' | Should -BeTrue
        $script:localExitCode | Should -Be 125
    }

    It 'preserves compound shell syntax, literal quotes, and a nonzero exit status' {
        # A quoted long no-op exercises escaping without producing output.
        $command = "printf '%s\n' `"it's literal`"; : '" + ('x' * 450) + "'; printf '%s\n' second; exit 17"
        Invoke-LocalInput @(Get-GuiFetchExecutionInput -CommandLine $command) | Should -BeExactly "it's literal`nsecond"
        $script:localExitCode | Should -Be 17
    }

    It 'executes an apostrophe-heavy command without changing its quoting' {
        $command = ": " + ("''" * 250)
        Invoke-LocalInput @(Get-GuiFetchExecutionInput -CommandLine $command) | Should -BeExactly ''
        $script:localExitCode | Should -Be 0
    }

    It 'rejects a changed chunk before executing any payload' {
        $command = "echo EXECUTED; : '" + ('x' * 450) + "'"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        $lines[1] = $lines[1].Replace('x', 'z')
        Invoke-LocalInput $lines | Should -BeExactly 'NONZERO SCRIPT EXIT: GUI command integrity mismatch'
        $script:localExitCode | Should -Be 125
    }

    It 'rejects a missing chunk and cannot reuse a parent shell variable' {
        $command = "echo EXECUTED; : '" + ('x' * 450) + "'"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        $missing = @('__y=stale') + @($lines[0]) + @($lines[2..($lines.Count - 1)])
        Invoke-LocalInput $missing | Should -BeExactly 'NONZERO SCRIPT EXIT: GUI command integrity mismatch'
        $script:localExitCode | Should -Be 125
    }

    It 'executes nothing when preparation ends before the closing line' {
        $command = "echo EXECUTED; : '" + ('x' * 450) + "'"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        $output = Invoke-LocalInput $lines[0..($lines.Count - 2)]
        $output | Should -Not -Match 'EXECUTED'
        $script:localExitCode | Should -Not -Be 0
    }

    It 'preserves an outer shell variable and leaves no staging state' {
        $command = ": '" + ('x' * 450) + "'"
        $lines = @('__y=outer') + @(Get-GuiFetchExecutionInput -CommandLine $command) + @('printf %s "$__y"')
        Invoke-LocalInput $lines | Should -BeExactly 'outer'
        $script:localExitCode | Should -Be 0
    }

    It 'keeps sensitive observation values in the context and out of the parent shell' {
        $context = @{Step=@{sensitive=$true};RepoRoot=$script:context.RepoRoot;StepInvocationId='9dd7e79e0e404f0b8aa334f1337540e9';SequenceInvocationId='2ba53dd6961e4beea8ec17e8416f8651'}
        $result = Get-FetchExecutionContext -Context $context -CommandLine 'printf ready'
        $result.Fields.EXEC_PROFILE | Should -BeExactly '0'
        $result.Fields.EXEC_KEEP_PROFILE | Should -BeExactly '0'
        $result.Fields.E_SI | Should -BeExactly $context.StepInvocationId
        $result.Fields.E_QI | Should -BeExactly $context.SequenceInvocationId
        $result.Launch | Should -Not -Match 'EXEC_PROFILE|E_SI|E_QI'
    }

    It 'uses independent identities for consecutive invocations' {
        $first = Get-FetchExecutionContext -Context $script:context -CommandLine 'printf ready'
        $second = Get-FetchExecutionContext -Context $script:context -CommandLine 'printf ready'
        $first.Id | Should -Not -Be $second.Id
        $first.Fields.E_SI | Should -BeExactly $second.Fields.E_SI
    }
}
Describe 'Compact GUI envelope construction' {
    It 'reduces physical input bytes and lines for a representative workload' {
        $compact = @(Get-GuiFetchEnvelopeInput -FetchContext $script:fetchContext -CommandLine $script:payload)
        $legacy = @(Get-GuiFetchExecutionInput -CommandLine $script:fetchContext.Command)
        ($compact | Measure-Object Length -Sum).Sum | Should -BeLessThan ($legacy | Measure-Object Length -Sum).Sum
        $compact.Count | Should -BeLessThan $legacy.Count
        $compact[-1] | Should -Match '^yfe --gui [0-9a-f]{64} "\$__y"\)$'
        foreach($line in $compact[0..($compact.Count-2)]) { $line.Length | Should -BeLessOrEqual 240 }
        foreach($line in $compact) { $line.Length | Should -BeLessOrEqual 400; Test-OCRMatch -Text $line -Pattern 'NONZERO SCRIPT EXIT:' | Should -BeFalse }
    }

    It 'retains legacy construction for NUL or an over-budget command' {
        @(Get-GuiFetchEnvelopeInput -FetchContext $script:fetchContext -CommandLine ('echo'+[char]0+'hidden')) | Should -HaveCount 0
        @(Get-GuiFetchEnvelopeInput -FetchContext $script:fetchContext -CommandLine ('x'*65536)) | Should -HaveCount 0
    }

    It 'refuses invalid compact digests and encodings before typing' {
        {Get-GuiFetchExecutionInput -CommandLine 'AAAA' -CompactEnvelope -EnvelopeDigest ('G'*64)} | Should -Throw
        {Get-GuiFetchExecutionInput -CommandLine "a'; echo bad" -CompactEnvelope -EnvelopeDigest ('0'*64)} | Should -Throw
    }
}

Describe 'Compact GUI envelope in the real guest Bash launcher' -Skip:(-not $script:contextShellAvailable) {
    BeforeAll {
        function ConvertTo-TestEnvelopeInput([byte[]]$Bytes, [switch]$CorruptFooter) {
            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
            $stream = [IO.MemoryStream]::new()
            $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionLevel]::Optimal, $true)
            $gzip.Write($Bytes, 0, $Bytes.Length); $gzip.Dispose()
            $compressed = $stream.ToArray(); $stream.Dispose()
            if($CorruptFooter) { $compressed[-8] = $compressed[-8] -bxor 1 }
            return @(Get-GuiFetchExecutionInput -CommandLine ([Convert]::ToBase64String($compressed)) -CompactEnvelope -EnvelopeDigest $digest)
        }
        function Get-TestEnvelopeByteArray([string[]]$Lines) {
            $encoded = -join @($Lines[0..($Lines.Count-2)] | ForEach-Object { [regex]::Match($_, "'([^']*)'").Groups[1].Value })
            $inputStream = [IO.MemoryStream]::new([Convert]::FromBase64String($encoded))
            $gzip = [IO.Compression.GZipStream]::new($inputStream,[IO.Compression.CompressionMode]::Decompress)
            $outputStream = [IO.MemoryStream]::new()
            $gzip.CopyTo($outputStream);$gzip.Dispose();$inputStream.Dispose()
            $bytes=$outputStream.ToArray();$outputStream.Dispose()
            return ,$bytes
        }
        function Invoke-TestCompactInput([string[]]$Lines) {
            $output = Invoke-LocalInput (@($script:launcherDriver) + $Lines)
            return $output
        }
    }

    It 'reports its exact capability without preparing or executing a command' {
        Invoke-TestCompactInput @('yfe --gui-capability') | Should -BeExactly 'YFE_GUI_1'
        $script:localExitCode | Should -Be 0
    }

    It 'preserves Unicode, quotes, compound syntax, invocation IDs, mask and trailing newlines' {
        $command = "printf '%s|' `"it's caf$([char]0x00e9)`"; printf '%s|' `"`$E_SI`"; umask`n# trailing newline`n"
        $context = Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $lines = @(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        Invoke-TestCompactInput (@('umask 0027') + $lines) | Should -BeExactly ("it's caf$([char]0x00e9)|"+$script:context.StepInvocationId+'|0027')
        $script:localExitCode | Should -Be 0
    }

    It 'consumes the prepared identity once and preserves the payload exit code' {
        $command='echo EXECUTED; exit 17'
        $context=Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $lines=@(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        Invoke-TestCompactInput $lines | Should -BeExactly 'EXECUTED'
        $script:localExitCode | Should -Be 17
        $output=Invoke-TestCompactInput ($lines + @($context.Launch))
        ([regex]::Matches($output,'EXECUTED')).Count | Should -Be 1
        $output | Should -Match 'YFE_CONTEXT_MISSING'
        $script:localExitCode | Should -Be 125
    }

    It 'rejects corrupt CRC/footer bytes even when all uncompressed bytes and their SHA are intact' {
        $command='echo EXECUTED'
        $context=Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $bytes=Get-TestEnvelopeByteArray @(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        $output=Invoke-TestCompactInput @(ConvertTo-TestEnvelopeInput $bytes -CorruptFooter)
        $output | Should -Match 'NONZERO SCRIPT EXIT: YFE_GUI_ENCODING'
        $output | Should -Not -Match 'EXECUTED'
        $script:localExitCode | Should -Be 125
    }

    It 'rejects a wrong full envelope SHA or a missing chunk before execution' -ForEach @(@{Damage='digest'},@{Damage='chunk'}) {
        $command='echo EXECUTED; : '+('x'*500)
        $context=Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $lines=@(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        if($Damage -eq 'digest') { $lines[-1]=[regex]::Replace($lines[-1],'[0-9a-f]{64}',('0'*64)) }
        else { $lines=@($lines[0])+@($lines[2..($lines.Count-1)]) }
        $output=Invoke-TestCompactInput $lines
        $output | Should -Match 'NONZERO SCRIPT EXIT: YFE_GUI_'
        $output | Should -Not -Match 'EXECUTED'
        $script:localExitCode | Should -Be 125
    }

    It 'records the length and digest it received when a typed character arrives twice' {
        $command = 'echo EXECUTED; : ' + (-join (1..30 | ForEach-Object { [guid]::NewGuid().ToString('N') }))
        $context = Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $lines = @(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        $lines.Count | Should -BeGreaterThan 2
        $sent = Get-GuiFetchEnvelopeTransfer -Line $lines
        # A key whose release arrives late repeats inside one staged chunk.
        $lines[1] = $lines[1].Substring(0, 12) + $lines[1][11] + $lines[1].Substring(12)
        $received = Get-GuiFetchEnvelopeTransfer -Line $lines
        $read = 'cat -- "$YURUNA_CONTEXT_TEST_DIRECTORY/rejection/' + $sent.envelopeDigest + '"'
        $output = Invoke-TestCompactInput (@($lines) + $read)
        $output | Should -Match 'NONZERO SCRIPT EXIT: YFE_GUI_(ENCODING|DIGEST)'
        $output | Should -Not -Match 'EXECUTED'
        $output | Should -Match '(?m)^code=YFE_GUI_(ENCODING|DIGEST)$'
        $output | Should -Match ('(?m)^receivedChars={0}$' -f ($sent.encodedChars + 1))
        $output | Should -Match ('(?m)^receivedSha256={0}$' -f $received.encodedSha256)
    }

    It 'leaves no record when the envelope runs' {
        $command = 'echo EXECUTED'
        $context = Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $lines = @(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        $sent = Get-GuiFetchEnvelopeTransfer -Line $lines
        $output = Invoke-TestCompactInput (@($lines) + ('ls -A -- "$YURUNA_CONTEXT_TEST_DIRECTORY/rejection" 2>/dev/null; echo RECORDS_LISTED'))
        $output | Should -Match 'EXECUTED'
        $output | Should -Not -Match $sent.envelopeDigest
        $output | Should -Match 'RECORDS_LISTED'
    }

    It 'cannot execute an envelope whose command differs from its bound metadata' {
        $context=Get-FetchExecutionContext -Context $script:context -CommandLine 'echo EXECUTED' -Compress
        $output=Invoke-TestCompactInput @(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine 'echo ALTERED')
        $output | Should -Match 'NONZERO SCRIPT EXIT: YFE_COMMAND_DIGEST'
        $output | Should -Not -Match 'EXECUTED|ALTERED'
        $script:localExitCode | Should -Be 125
    }

    It 'validates the context ID, full context SHA and original field allowlist' -ForEach @(
        @{Damage='id';Reason='CONTEXT_ID'},@{Damage='sha';Reason='CONTEXT_DIGEST'},@{Damage='field';Reason='CONTEXT_FIELD'}
    ) {
        $command='echo EXECUTED'
        $context=Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        if($Damage -eq 'id') { $context.Id='aaaaaaaaaaa' }
        if($Damage -eq 'field') {
            $text=[Text.Encoding]::UTF8.GetString($context.Bytes)+"UNKNOWN=MQ==`n"
            $context.Bytes=[Text.Encoding]::UTF8.GetBytes($text)
        }
        $lines=@(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        if($Damage -eq 'sha') {
            $text=[Text.Encoding]::UTF8.GetString((Get-TestEnvelopeByteArray $lines))
            $text=[regex]::Replace($text,'(?m)^[0-9a-f]{64}$',('0'*64))
            $lines=@(ConvertTo-TestEnvelopeInput ([Text.Encoding]::UTF8.GetBytes($text)))
        }
        $output=Invoke-TestCompactInput $lines
        $output | Should -Match "NONZERO SCRIPT EXIT: YFE_$Reason"
        $output | Should -Not -Match 'EXECUTED'
        $script:localExitCode | Should -Be 125
    }

    It 'bounds gzip expansion and rejects trailing envelope bytes or a NUL command' -ForEach @(
        @{Damage='oversize';Reason='GUI_SIZE'},@{Damage='trailing';Reason='GUI_SIZE'},@{Damage='nul';Reason='GUI_ENCODING'}
    ) {
        $command='echo EXECUTED'
        $context=Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $bytes=Get-TestEnvelopeByteArray @(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        if($Damage -eq 'oversize') { $bytes=[Text.Encoding]::UTF8.GetBytes('x'*65537) }
        else {
            $text=[Text.Encoding]::UTF8.GetString($bytes)
            if($Damage -eq 'trailing') { $text+='extra' }
            else { $text=$text.Replace($command,('echo'+[char]0+'EXECUTED')) }
            $bytes=[Text.Encoding]::UTF8.GetBytes($text)
        }
        $output=Invoke-TestCompactInput @(ConvertTo-TestEnvelopeInput $bytes)
        $output | Should -Match "NONZERO SCRIPT EXIT: YFE_$Reason"
        $output | Should -Not -Match 'EXECUTED'
        $script:localExitCode | Should -Be 125
    }

    It 'executes nothing before the closing guard and preserves the parent staging variable' {
        $command='echo EXECUTED'
        $context=Get-FetchExecutionContext -Context $script:context -CommandLine $command -Compress
        $lines=@(Get-GuiFetchEnvelopeInput -FetchContext $context -CommandLine $command)
        Invoke-TestCompactInput $lines[0..($lines.Count-2)] | Should -Not -Match 'EXECUTED'
        $script:localExitCode | Should -Not -Be 0
        Invoke-TestCompactInput (@('__y=outer')+$lines+@('printf %s "$__y"')) | Should -BeExactly "EXECUTED`nouter"
        $script:localExitCode | Should -Be 0
    }
}

Describe 'Compact GUI capability fallback' {
    BeforeAll {
        $fixture=@'
$script:keyExists=$true
$script:address='192.0.2.42'
$script:result=@{success=$true;exitCode=0;output="YFE_GUI_1`n"}
$script:probeCalls=0
function Get-ProvenGuestAddress {param($VMName) $null=$VMName; return $script:address}
function Test-Path {param($LiteralPath,$PathType) $null=$LiteralPath;$null=$PathType;return $script:keyExists}
function Invoke-GuestSsh {
    param($VMName,$GuestKey,$User,$ResolvedAddress,$PrivateKeyPath,$AddressWaitSeconds,$TimeoutSeconds,$MaxCapturedChars,$Command)
    $script:probeCalls++;$script:arguments=$PSBoundParameters
    if($script:throwProbe) {throw 'offline'}
    return $script:result
}
'@
        $supportSource=(Get-FunctionSource 'Test-GuiFetchEnvelopeSupported').Replace('$PSScriptRoot',"'/fixture/test/modules'")
        $script:capabilityModule=New-Module -ScriptBlock ([scriptblock]::Create($fixture+"`n"+$supportSource))
    }
    BeforeEach {
        & $script:capabilityModule {$script:keyExists=$true;$script:address='192.0.2.42';$script:probeCalls=0;$script:throwProbe=$false;$script:result=@{success=$true;exitCode=0;output="YFE_GUI_1`n"}}
        $script:capabilityContext=@{VMName='vm';GuestKey='guest.ubuntu.server.26';Vars=@{username='fixture'}}
    }
    It 'uses only an exact capability answer and existing connection inputs within the small budget' {
        & $script:capabilityModule {param($c) Test-GuiFetchEnvelopeSupported $c} $script:capabilityContext | Should -BeTrue
        & $script:capabilityModule {
            $script:probeCalls | Should -Be 1
            $script:arguments.ResolvedAddress | Should -BeExactly '192.0.2.42'
            $script:arguments.PrivateKeyPath | Should -Match 'status[/\\]ssh[/\\]yuruna_ed25519$'
            $script:arguments.AddressWaitSeconds | Should -Be 0
            $script:arguments.TimeoutSeconds | Should -Be 1
            $script:arguments.MaxCapturedChars | Should -Be 4096
            $script:arguments.Command | Should -BeExactly '/usr/local/bin/yfe --gui-capability'
        }
    }
    It 'falls back before SSH when no address, key or user was established' -ForEach @(@{Missing='address'},@{Missing='key'},@{Missing='user'}) {
        if($Missing -eq 'address') {& $script:capabilityModule {$script:address=''}}
        if($Missing -eq 'key') {& $script:capabilityModule {$script:keyExists=$false}}
        if($Missing -eq 'user') {$script:capabilityContext.Vars=@{}}
        & $script:capabilityModule {param($c) Test-GuiFetchEnvelopeSupported $c} $script:capabilityContext | Should -BeFalse
        & $script:capabilityModule {$script:probeCalls | Should -Be 0}
    }
    It 'falls back on old seed, offline SSH, timeout, corrupt token or nonzero status without caching' -ForEach @(
        @{Failure='old'},@{Failure='offline'},@{Failure='timeout'},@{Failure='token'},@{Failure='status'}
    ) {
        & $script:capabilityModule {param($f)
            if($f -eq 'offline') {$script:throwProbe=$true}
            elseif($f -eq 'timeout') {$script:result=@{success=$false;exitCode=-1;output=''}}
            elseif($f -eq 'status') {$script:result=@{success=$true;exitCode=125;output='YFE_GUI_1'}}
            else {$script:result=@{success=$true;exitCode=0;output=if($f -eq 'old') {'YFE_ARGUMENTS'} else {'YFE_GUI_1 extra'}}}
        } $Failure
        & $script:capabilityModule {param($c) Test-GuiFetchEnvelopeSupported $c} $script:capabilityContext | Should -BeFalse
        & $script:capabilityModule {$script:throwProbe=$false;$script:result=@{success=$true;exitCode=0;output='YFE_GUI_1'}}
        & $script:capabilityModule {param($c) Test-GuiFetchEnvelopeSupported $c} $script:capabilityContext | Should -BeTrue
        & $script:capabilityModule {$script:probeCalls | Should -Be 2}
    }
}

Describe 'GUI fetch input stall detection' {
    BeforeAll {
        $script:stallModule = New-Module -ScriptBlock ([scriptblock]::Create(
            (Get-FunctionSource 'Test-GuiFetchInputStalled') + "`n" + (Get-FunctionSource 'Get-GuiFetchPayloadState')))
    }

    It 'reports an open staged subshell whose last visible line is a continuation prompt' {
        $tail = "yuuser26@yuhost26:~`$ (unset __y;__y='if (set -o pipefail`n> __y+='SGsD';`n> __y+='inPX"
        & $script:stallModule { param($t) Test-GuiFetchInputStalled -OcrTail $t } $tail | Should -BeTrue
    }

    It 'tolerates OCR noise in the continuation prompt and staging variable' {
        $tail = "> __uss ' EBmNu`n> __y+s ' YRUaUR"
        & $script:stallModule { param($t) Test-GuiFetchInputStalled -OcrTail $t } $tail | Should -BeTrue
    }

    It 'reports a staged prompt whose typed echo wraps onto rows without a prompt' {
        $tail = "> __y+='SGsDHnSV4 inPXBROVOS/Fusj/SHHZURUNGex/tHYNUtF`nJecSRuwoTdhrT32VJ1U7WIYBu2sdH inP 1SkFG1+H2SHCOX`nMV+NpDJxLUpsfvE/C20789ak 7a3UZ"
        & $script:stallModule { param($t) Test-GuiFetchInputStalled -OcrTail $t } $tail | Should -BeTrue
    }

    It 'does not report a finished command even when the echo still shows the staging variable' {
        $tail = "> __y+='last';`nguard ran`nyuuser26@yuhost26:~`$ "
        & $script:stallModule { param($t) Test-GuiFetchInputStalled -OcrTail $t } $tail | Should -BeFalse
    }

    It 'does not report a continuation prompt that has nothing to do with the staging variable' {
        & $script:stallModule { Test-GuiFetchInputStalled -OcrTail "> hello`n> world" } | Should -BeFalse
    }

    It 'builds a probe for the context id and reads only a known state' {
        $script:probeCalls = [System.Collections.Generic.List[string]]::new()
        & $script:stallModule {
            function Invoke-GuestSsh { param($VMName,$GuestKey,$Command,$TimeoutSeconds) $script:probeCommand = [string]$Command; $script:probeTarget = "$VMName/$GuestKey"; $script:probeTimeout = $TimeoutSeconds; return $script:probeResult }
            $script:probeResult = @{success=$true;output="NOT_PREPARED`n"}
            Get-GuiFetchPayloadState -VMName 'v' -GuestKey 'g' -ContextId '7c4e2a91b80' | Should -Be 'NOT_PREPARED'
            $script:probeCommand | Should -Match 'fetch-context/7c4e2a91b80'
            $script:probeCommand | Should -Match 'pgrep'
            $script:probeTarget | Should -Be 'v/g'
            $script:probeTimeout | Should -BeGreaterThan 0
            $script:probeResult = @{success=$true;output='something else'}
            Get-GuiFetchPayloadState -VMName 'v' -GuestKey 'g' -ContextId '7c4e2a91b80' | Should -BeNullOrEmpty
            Get-GuiFetchPayloadState -VMName 'v' -GuestKey 'g' -ContextId '../etc' | Should -BeNullOrEmpty
        }
    }

    It 'does not report input the launcher answered even when OCR misreads the returning prompt' {
        # The sentinel is the launcher's own answer; the typed echo never carries it.
        & $script:stallModule { param($t) Test-GuiFetchInputStalled -OcrTail $t } $script:RefusedEnvelopeOcrTail | Should -BeFalse
        $tail = "> __y+='H4sI';`n> yfe --gui " + ('a' * 64) + " `"`$__y`")`nNONZERO SCRIPT EXIT: YFE_GUI_DIGEST`nyuuser26@yuhost26:~S"
        & $script:stallModule { param($t) Test-GuiFetchInputStalled -OcrTail $t } $tail | Should -BeFalse
    }

    It 'treats an empty or blank tail as not stalled' {
        & $script:stallModule { Test-GuiFetchInputStalled -OcrTail '' } | Should -BeFalse
        & $script:stallModule { Test-GuiFetchInputStalled -OcrTail "`n  `n" } | Should -BeFalse
    }
}

Describe 'GUI fetch handler integration' {
    BeforeAll {
        $registration = $script:ast.Find({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Register-SequenceAction' -and $n.Extent.Text.StartsWith("Register-SequenceAction -Name 'fetchAndExecute'")}, $true)
        $handler = ($registration.CommandElements | Where-Object {$_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]} | Select-Object -Last 1).ScriptBlock.Extent.Text
        $providerAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'Test.HostIO.Utm.psm1'), [ref]$null, [ref]$null)
        $providerRegistration = $providerAst.Find({param($n)
            $n -is [Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Register-HostIOProvider' -and
            $n.Extent.Text.StartsWith("Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Text'")
        }, $true)
        $provider = ($providerRegistration.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.ScriptBlockExpressionAst]
        } | Select-Object -Last 1).ScriptBlock.Extent.Text
        $fixture = @'
$script:NonzeroScriptExitSentinel='NONZERO SCRIPT EXIT:'
$script:FetchExecuteTypedCharWarn=400
$script:ShellRejectedCommandPattern=@('command not found','No such file or directory')
$script:ShellRejectionWindowSeconds=20
$script:sent=[System.Collections.Generic.List[string]]::new()
$script:shellEscapeFlags=[System.Collections.Generic.List[bool]]::new()
$script:drainDelays=[System.Collections.Generic.List[double]]::new()
$script:charDelays=[System.Collections.Generic.List[int]]::new()
$script:compressionRequested=$false
$script:preparedCommand=''
$script:utmCalls=[System.Collections.Generic.List[object]]::new()
$script:useUtmProvider=$false
$script:vncCalls=0
$script:waited=0
$script:captured=0
$script:failSend=0
$script:waitResult=$true
$script:Fail=@{WaitForTextOcrTail='';StepInputLost=$null}
$script:sshResult=@{success=$true;output='NOT_PREPARED'}
$script:rejectionResult=@{success=$true;output=''}
$script:sshCalls=[System.Collections.Generic.List[string]]::new()
$script:events=[System.Collections.Generic.List[object]]::new()
$script:waitResults=[System.Collections.Generic.Queue[bool]]::new()
$script:matchedPattern=$null
function Invoke-GuestSsh { param($VMName,$GuestKey,$Command,$TimeoutSeconds,$TransportRetryCount,$DetachToken) $null=$VMName;$null=$GuestKey;$null=$TransportRetryCount;$null=$DetachToken;$script:sshCalls.Add([string]$Command);$script:sshTimeout=$TimeoutSeconds; if ([string]$Command -match 'gui-rejection') { return $script:rejectionResult }; return $script:sshResult }
function Send-CycleEventSafely { param($EventRecord) $script:events.Add($EventRecord) }
function Get-FetchExecutionContext {
    param($Context,$CommandLine,[switch]$Compress)
    $null=$Context;$null=$CommandLine
    $script:compressionRequested=[bool]$Compress
    return [pscustomobject]@{Id='7c4e2a91b80';Command=$script:preparedCommand;Launch='yfe 7c4e2a91b80 bash -c ''echo ready'''}
}
function Get-GuiFetchEnvelopeInput { param($FetchContext,$CommandLine) $null=$FetchContext;$null=$CommandLine; $script:compactInput }
function Test-GuiFetchEnvelopeSupported { param($Context) $null=$Context; $script:capabilityCalls++; return $script:compactSupported }
function Invoke-TypeDrainEnter {
    param($Context,$Text,$CharDelayMs,$DelaySeconds,[switch]$ShellEscape)
    $script:sent.Add($Text)
    $script:shellEscapeFlags.Add([bool]$ShellEscape)
    $script:drainDelays.Add([double]$DelaySeconds)
    $script:charDelays.Add([int]$CharDelayMs)
    if ($script:sent.Count -eq $script:failSend) { return $false }
    if ($script:useUtmProvider) {
        return Invoke-TestUtmProvider @{VMName=$Context.VMName;Text=$Text;CharDelayMs=$CharDelayMs;ShellEscape=[bool]$ShellEscape}
    }
    return $true
}
function Send-TextVNC { $script:vncCalls++; return $false }
function Send-TextUTM {
    param($VMName,$Text,$CharDelayMs,[switch]$ShellEscape)
    $script:utmCalls.Add(@{VMName=$VMName;Text=$Text;CharDelayMs=$CharDelayMs;ShellEscape=[bool]$ShellEscape})
    return $true
}
function Wait-ForText { param($FreshMatch,$EarlyFailurePattern,$FailurePattern,[switch]$EndOnGuestLivelock) $script:endOnLivelock=[bool]$EndOnGuestLivelock; $script:waited++; $script:fresh=$FreshMatch; $script:early=$EarlyFailurePattern; $script:failure=$FailurePattern; $result = if ($script:waitResults.Count) { $script:waitResults.Dequeue() } else { $script:waitResult }; $script:Fail.WaitForTextMatchedFailurePattern = if ($result) { $null } else { $script:matchedPattern }; return $result }
function Save-FetchExecutionEvidence { param($Context,$Succeeded,$ElapsedSeconds) $script:captured++; $script:succeeded=$Succeeded }
'@
        $helpers = (Get-FunctionSource 'Get-GuiFetchExecutionInput') + "`n" + (Get-FunctionSource 'Resolve-SequenceCharDelay') + "`n" + (Get-FunctionSource 'Test-GuiFetchInputStalled') + "`n" + (Get-FunctionSource 'Get-GuiFetchPayloadState') +
            "`n" + (Get-FunctionSource 'Get-GuiFetchEnvelopeTransfer') + "`n" + (Get-FunctionSource 'Get-GuiFetchRejection')
        $script:handlerModule = New-Module -ScriptBlock ([scriptblock]::Create(
            $fixture + "`n" + $helpers + "`nfunction Invoke-TestUtmProvider $provider`nfunction Invoke-TestHandler $handler"))
    }

    BeforeEach {
        & $script:handlerModule {
            $script:sent.Clear();$script:shellEscapeFlags.Clear();$script:drainDelays.Clear();$script:charDelays.Clear();$script:utmCalls.Clear()
            $script:compressionRequested=$false;$script:preparedCommand="echo ready; : '" + ('x' * 450) + "'"
            $script:waited=0;$script:captured=0;$script:failSend=0;$script:vncCalls=0;$script:useUtmProvider=$false
            $script:waitResult=$true;$script:Fail.WaitForTextOcrTail='';$script:Fail.StepInputLost=$null
            $script:sshResult=@{success=$true;output='NOT_PREPARED'};$script:sshCalls.Clear()
            $script:rejectionResult=@{success=$true;output=''};$script:events.Clear();$script:waitResults.Clear();$script:matchedPattern=$null;$script:Fail.StepLauncherRejection=$null
            $script:compactInput=@();$script:compactSupported=$false;$script:capabilityCalls=0
        }
        $script:handlerContext = @{HostType='host.macos.utm';VMName='vm';GuestKey='guest.ubuntu.server.26';StepInvocationId='9dd7e79e0e404f0b8aa334f1337540e9';SequenceInvocationId='2ba53dd6961e4beea8ec17e8416f8651';
            Step=@{text=$script:payload;waitPattern='FETCHED AND EXECUTED:';timeoutSeconds=1200;freshMatchTailLines=60};
            Vars=@{};ExpandVariable={param($value,$vars) $null=$vars; $value};DefaultTimeoutSeconds=1;DefaultPollSeconds=1}
    }

    It 'sends bounded GUI lines and preserves the existing completion and failure monitor' {
        $result = @(& $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext)
        $result | Should -HaveCount 1
        $result[0] | Should -BeTrue
        & $script:handlerModule {
            $script:compressionRequested | Should -BeTrue
            $script:sent.Count | Should -BeGreaterThan 1
            foreach ($line in $script:sent) { $line.Length | Should -BeLessOrEqual 400 }
            @($script:shellEscapeFlags | Where-Object { $_ }) | Should -HaveCount 0
            foreach ($delay in $script:drainDelays) { $delay | Should -Be 2 }
            $script:waited | Should -Be 1
            $script:fresh | Should -BeTrue
            $script:early | Should -Contain 'command not found'
            $script:failure | Should -Contain 'NONZERO SCRIPT EXIT:'
            $script:captured | Should -Be 1
            $script:succeeded | Should -BeTrue
        }
    }

    It 'ends a livelocked payload wait without replay and still saves evidence' {
        & $script:handlerModule { $script:preparedCommand='echo ready'; $script:waitResult=$false }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeFalse
        & $script:handlerModule {
            $script:endOnLivelock | Should -BeTrue
            $script:sent | Should -HaveCount 1
            $script:waited | Should -Be 1
            $script:captured | Should -Be 1
            $script:succeeded | Should -BeFalse
        }
    }

    It 'uses fewer compact lines without changing platform drains or character pacing' -ForEach @(
        @{HostType='host.macos.utm';Intermediate=2}, @{HostType='host.windows.hyper-v';Intermediate=0}, @{HostType='host.ubuntu.kvm';Intermediate=0}
    ) {
        $script:handlerContext.HostType=$HostType
        $script:handlerContext.DefaultCharDelayMs=17
        & $script:handlerModule { $script:compactSupported=$true; $script:compactInput=@('compact data;', 'compact guard)') }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeTrue
        & $script:handlerModule {param($expected)
            $script:sent | Should -HaveCount 2
            $script:sent[0] | Should -BeExactly 'compact data;'
            $script:drainDelays[0] | Should -Be $expected
            $script:drainDelays[1] | Should -Be 2
            @($script:charDelays | Where-Object {$_ -ne 17}) | Should -HaveCount 0
            $script:capabilityCalls | Should -Be 1
        } $Intermediate
    }

    It 'keeps legacy input when capability is absent or compact input grows' {
        foreach($supported in @($false,$true)) {
            & $script:handlerModule {param($s)
                $script:sent.Clear();$script:compactSupported=$s
                $script:compactInput=if($s) {@('x'*3000)} else {@('compact data;', 'compact guard)')}
            } $supported
            & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeTrue
            & $script:handlerModule { $script:sent[-1] | Should -Match 'sha256sum' }
        }
    }

    It 'does not retry legacy input after a compact send or completion failure' {
        & $script:handlerModule { $script:compactSupported=$true; $script:compactInput=@('compact data;', 'compact guard)');$script:waitResult=$false }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeFalse
        & $script:handlerModule { $script:sent | Should -HaveCount 2; $script:capabilityCalls | Should -Be 1 }
    }

    It 'retains the default launch delay and shell escaping for a single input line' {
        & $script:handlerModule { $script:preparedCommand='echo ready' }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeTrue
        & $script:handlerModule {
            $script:sent | Should -HaveCount 1
            $script:drainDelays[0] | Should -Be 2
            $script:shellEscapeFlags[0] | Should -BeTrue
        }
    }

    It 'settles only the final line on a backend that does not need a settle between staged lines' {
        $script:handlerContext.HostType='host.ubuntu.kvm'
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeTrue
        & $script:handlerModule {
            $script:sent.Count | Should -BeGreaterThan 1
            $script:drainDelays[-1] | Should -Be 2
            @($script:drainDelays.GetRange(0, $script:drainDelays.Count - 1) | Where-Object { $_ -ne 0 }) | Should -HaveCount 0
        }
    }

    It 'honors an explicit drain delay on every verified staging line' {
        $script:handlerContext.Step.delaySeconds=3.5
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeTrue
        & $script:handlerModule {
            $script:drainDelays.Count | Should -Be $script:sent.Count
            foreach ($delay in $script:drainDelays) { $delay | Should -Be 3.5 }
        }
    }

    It 'honors an explicit zero drain delay including the final launch line' {
        $script:handlerContext.Step.delaySeconds=0
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeTrue
        & $script:handlerModule {
            foreach ($delay in $script:drainDelays) { $delay | Should -Be 0 }
        }
    }

    It 'classifies a stalled staged input as input_lost when the guest holds no prepared payload' {
        & $script:handlerModule { $script:waitResult = $false; $script:Fail.WaitForTextOcrTail = "yuuser26@yuhost26:~`$ (unset __y;__y='if (set -o pipefail`n> __y+='H4sI';`n> __y+='AAAA" }
        $result = & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext
        $result | Should -BeFalse
        & $script:handlerModule {
            $script:Fail.StepInputLost | Should -BeTrue
            $script:sshCalls | Should -HaveCount 1
            $script:sshCalls[0] | Should -Match '7c4e2a91b80'
        }
    }

    It 'does not classify a stalled-looking screen when the guest prepared the payload' {
        & $script:handlerModule { $script:sshResult = @{success=$true;output='PREPARED'} }
        & $script:handlerModule { $script:waitResult = $false; $script:Fail.WaitForTextOcrTail = "> __y+='H4sI';`n> __y+='AAAA" }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeFalse
        & $script:handlerModule { $script:Fail.StepInputLost | Should -BeNullOrEmpty }
    }

    It 'does not classify a stalled-looking screen while the guest is still running a fetch' {
        & $script:handlerModule { $script:sshResult = @{success=$true;output='RUNNING'} }
        & $script:handlerModule { $script:waitResult = $false; $script:Fail.WaitForTextOcrTail = "> __y+='H4sI';`n> __y+='AAAA" }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeFalse
        & $script:handlerModule { $script:Fail.StepInputLost | Should -BeNullOrEmpty }
    }

    It 'does not classify when the guest cannot be asked' {
        & $script:handlerModule { $script:sshResult = @{success=$false;output=''} }
        & $script:handlerModule { $script:waitResult = $false; $script:Fail.WaitForTextOcrTail = "> __y+='H4sI';`n> __y+='AAAA" }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeFalse
        & $script:handlerModule { $script:Fail.StepInputLost | Should -BeNullOrEmpty }
    }

    It 'does not ask the guest when the screen shows no staged input' {
        & $script:handlerModule { $script:sshResult = @{success=$true;output='NOT_PREPARED'} }
        & $script:handlerModule { $script:waitResult = $false; $script:Fail.WaitForTextOcrTail = "yuruna guard ran`nyuuser26@yuhost26:~`$ " }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeFalse
        & $script:handlerModule {
            $script:sshCalls | Should -HaveCount 0
            $script:Fail.StepInputLost | Should -BeNullOrEmpty
        }
    }

    It 'does not classify a successful wait even when the tail looks staged' {
        & $script:handlerModule { $script:waitResult = $true; $script:Fail.WaitForTextOcrTail = "> __y+='H4sI';" }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext | Should -BeTrue
        & $script:handlerModule {
            $script:Fail.StepInputLost | Should -BeNullOrEmpty
            $script:sshCalls | Should -HaveCount 0
        }
    }

    It 'types a compact envelope once more after the launcher refused it as damaged and nothing ran' {
        & $script:handlerModule {
            $script:compactSupported = $true
            $script:compactInput = @("(unset __y;__y='QUJD';", "__y+='REVG';", ('yfe --gui ' + ('a' * 64) + ' "$__y")'))
            $script:waitResults.Enqueue($false); $script:waitResults.Enqueue($true)
            $script:matchedPattern = 'NONZERO SCRIPT EXIT:'
            $script:rejectionResult = @{success=$true;output="code=YFE_GUI_ENCODING`nreceivedChars=9`nreceivedSha256=$('b' * 64)`n"}
        }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext 3>$null | Should -BeTrue
        & $script:handlerModule {
            $script:waited | Should -Be 2
            $script:sent | Should -HaveCount 7
            $script:sent[3] | Should -BeExactly 'clear'
            ($script:sent[4..6] -join '|') | Should -BeExactly ($script:sent[0..2] -join '|')
            @($script:sshCalls | Where-Object { $_ -match 'gui-rejection/a{64}' }) | Should -HaveCount 1
            $script:events | Should -HaveCount 1
            $script:events[0].stack | Should -Be 'gui-envelope'
            $script:events[0].reason | Should -Be 'YFE_GUI_ENCODING: received 9 of 8 characters'
            $script:Fail.StepLauncherRejection.code | Should -Be 'YFE_GUI_ENCODING'
            $script:Fail.StepLauncherRejection.expectedChars | Should -Be 8
            $script:Fail.StepInputLost | Should -BeNullOrEmpty
        }
    }

    It 'does not type the envelope again when the guest holds a context or runs a fetch' -ForEach @(@{State='PREPARED'}, @{State='RUNNING'}) {
        & $script:handlerModule {param($state)
            $script:compactSupported = $true
            $script:compactInput = @("(unset __y;__y='QUJD';", "__y+='REVG';", ('yfe --gui ' + ('a' * 64) + ' "$__y")'))
            $script:waitResults.Enqueue($false); $script:waitResults.Enqueue($true)
            $script:matchedPattern = 'NONZERO SCRIPT EXIT:'
            $script:rejectionResult = @{success=$true;output="code=YFE_GUI_DIGEST`nreceivedChars=8`nreceivedSha256=$('b' * 64)`n"}
            $script:sshResult = @{success=$true;output=$state}
        } $State
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext 3>$null | Should -BeFalse
        & $script:handlerModule {
            $script:waited | Should -Be 1
            $script:sent | Should -HaveCount 3
            $script:events | Should -HaveCount 0
        }
    }

    It 'does not type the envelope again for a refusal that is not transport damage' {
        & $script:handlerModule {
            $script:compactSupported = $true
            $script:compactInput = @("(unset __y;__y='QUJD';", "__y+='REVG';", ('yfe --gui ' + ('a' * 64) + ' "$__y")'))
            $script:waitResults.Enqueue($false); $script:waitResults.Enqueue($true)
            $script:matchedPattern = 'NONZERO SCRIPT EXIT:'
            $script:rejectionResult = @{success=$true;output="code=YFE_CONTEXT_DIRECTORY`nreceivedChars=8`nreceivedSha256=$('b' * 64)`n"}
        }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext 3>$null | Should -BeFalse
        & $script:handlerModule {
            $script:waited | Should -Be 1
            $script:Fail.StepLauncherRejection.code | Should -Be 'YFE_CONTEXT_DIRECTORY'
        }
    }

    It 'types a refused envelope at most once more' {
        & $script:handlerModule {
            $script:compactSupported = $true
            $script:compactInput = @("(unset __y;__y='QUJD';", "__y+='REVG';", ('yfe --gui ' + ('a' * 64) + ' "$__y")'))
            $script:waitResults.Enqueue($false); $script:waitResults.Enqueue($false); $script:waitResults.Enqueue($true)
            $script:matchedPattern = 'NONZERO SCRIPT EXIT:'
            $script:rejectionResult = @{success=$true;output="code=YFE_GUI_ENCODING`nreceivedChars=9`nreceivedSha256=$('b' * 64)`n"}
        }
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext 3>$null | Should -BeFalse
        & $script:handlerModule {
            $script:waited | Should -Be 2
            $script:sent | Should -HaveCount 7
            $script:Fail.StepLauncherRejection.attempt | Should -Be 2
        }
    }

    It 'neither types again nor reports unclosed input when a launcher without a record refused it' {
        & $script:handlerModule {param($tail)
            $script:compactSupported = $true
            $script:compactInput = @("(unset __y;__y='QUJD';", "__y+='REVG';", ('yfe --gui ' + ('a' * 64) + ' "$__y")'))
            $script:waitResult = $false
            $script:matchedPattern = 'NONZERO SCRIPT EXIT:'
            $script:Fail.WaitForTextOcrTail = $tail
        } $script:RefusedEnvelopeOcrTail
        & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext 3>$null | Should -BeFalse
        & $script:handlerModule {
            $script:waited | Should -Be 1
            $script:Fail.StepInputLost | Should -BeNullOrEmpty
            $script:Fail.StepLauncherRejection | Should -BeNullOrEmpty
        }
    }

    It 'passes every staged line literally through the UTM fallback when VNC fails' {
        & $script:handlerModule { $script:useUtmProvider=$true }
        $result = & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext
        $result | Should -BeTrue
        & $script:handlerModule {
            $script:vncCalls | Should -Be $script:sent.Count
            $script:utmCalls | Should -HaveCount $script:sent.Count
            for ($index = 0; $index -lt $script:sent.Count; $index++) {
                $script:utmCalls[$index].Text | Should -BeExactly $script:sent[$index]
                $script:utmCalls[$index].ShellEscape | Should -BeFalse
                $script:utmCalls[$index].VMName | Should -Be 'vm'
            }
            $script:waited | Should -Be 1
        }
    }

    It 'stages even a short payload when its preparation needs bounded input' {
        $script:handlerContext.Step.text='echo ready'
        & $script:handlerModule { $script:useUtmProvider=$true }
        $result = & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext
        $result | Should -BeTrue
        & $script:handlerModule {
            $script:sent.Count | Should -BeGreaterThan 1
            $script:shellEscapeFlags[0] | Should -BeFalse
            $script:vncCalls | Should -Be $script:sent.Count
            $script:utmCalls[0].Text | Should -BeExactly $script:sent[0]
            $script:utmCalls[0].ShellEscape | Should -BeFalse
        }
    }

    It 'never submits the execution guard after a preparation-send failure' {
        & $script:handlerModule { $script:failSend=2 }
        $result = @(& $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext)
        $result | Should -HaveCount 1
        $result[0] | Should -BeFalse
        & $script:handlerModule {
            $script:sent | Should -HaveCount 2
            ($script:sent -join "`n") | Should -Not -Match 'eval'
            $script:waited | Should -Be 0
            $script:captured | Should -Be 1
            $script:succeeded | Should -BeFalse
        }
    }

    It 'uses the same bounded preparation on a Windows Hyper-V console' {
        $script:handlerContext.HostType='host.windows.hyper-v'
        $result = & $script:handlerModule {param($c) Invoke-TestHandler $c -WarningAction SilentlyContinue} $script:handlerContext
        $result | Should -BeTrue
        & $script:handlerModule {
            $script:sent.Count | Should -BeGreaterThan 1
            $script:shellEscapeFlags[0] | Should -BeFalse
            $script:waited | Should -Be 1
        }
    }
}
