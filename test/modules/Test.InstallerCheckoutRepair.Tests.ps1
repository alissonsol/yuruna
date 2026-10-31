<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42bf15a1-0a45-4de9-b937-54eada83f868
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install ubuntu macos checkout pipefail errexit pester
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
    Behavioral Pester guard on the helpers the macOS and Ubuntu installers
    share for reading the session's groups and repairing an existing checkout,
    run under the strict mode the installers run under.
.DESCRIPTION
    Both installers run with errexit, nounset and pipefail, and the Ubuntu one
    also with errtrace and an ERR trap that ends the run. Under those settings a
    command whose failure carries no meaning still decides the outcome:

      * id exits 1 when one of the session's groups has no name, after printing
        every name it could resolve, and pipefail lets that status override a
        grep that found the group.
      * a re-clone that cannot finish, after the checkout was moved aside, would
        end the run with no checkout at all.
      * a held .git/index.lock fails the line-ending rebuild, and a reset that
        fails after `rm --cached` would leave every file staged as deleted.

    The helpers are lifted out of both installers, which must carry them word
    for word, and the checkout tests run against real temporary git repositories
    so the git behavior is the real one.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -Command "Invoke-Pester -Path test/modules/Test.InstallerCheckoutRepair.Tests.ps1"
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    $script:SharedHelpers = @('group_names', 'unique_backup_path', 'reclone_checkout', 'renormalize_checkout')
    $script:Bodies = @{}
    $script:Texts = @{}
    foreach ($installer in @('install/ubuntu.kvm.sh', 'install/macos.utm.sh')) {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot $installer) -Raw
        $script:Texts[$installer] = $text
        $script:Bodies[$installer] = @{}
        foreach ($name in $script:SharedHelpers) {
            $script:Bodies[$installer][$name] = Get-YurunaTestShellFunction -Text $text -Name $name
        }
    }
    $script:Lifted = ($script:SharedHelpers | ForEach-Object { $script:Bodies['install/ubuntu.kvm.sh'][$_] }) -join "`n"

    # The Ubuntu installer's strict mode and an ERR trap that marks any firing,
    # inside a substitution or not.
    $script:Prelude = @'
set -Eeuo pipefail
trap 'echo ERR-TRAP-FIRED' ERR
YURUNA_ISSUES=()
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
note_issue() { YURUNA_ISSUES+=("$*"); printf 'ISSUE %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
'@

    function Invoke-HelperShell {
        param([Parameter(Mandatory)][string]$Body, [hashtable]$Environment = @{})
        $sandboxHome = Join-Path $TestDrive 'home'
        New-Item -ItemType Directory -Path $sandboxHome -Force | Out-Null
        # A private HOME and no system config keep the operator's git settings
        # (signing, hooks, aliases) out of the repositories these tests build.
        $env = @{ HOME = $sandboxHome; GIT_CONFIG_NOSYSTEM = '1'; GIT_TERMINAL_PROMPT = '0' }
        foreach ($key in $Environment.Keys) { $env[$key] = $Environment[$key] }
        return Invoke-YurunaTestShell -Body (@($script:Prelude, $script:Lifted, $Body) -join "`n") -Environment $env -TimeoutSeconds 60
    }

    # A bare remote with one commit on main, and a working clone of it.
    function New-GitFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds repositories under TestDrive, which Pester removes; not user-facing state.')]
        param([Parameter(Mandatory)][string]$Root)
        $null = Invoke-HelperShell -Body @"
set +E; trap - ERR
mkdir -p '$Root'
git init -q --bare -b main '$Root/remote.git'
git init -q -b main '$Root/seed'
printf 'line\n' > '$Root/seed/file.sh'
printf 'marker\n' > '$Root/seed/marker.txt'
git -C '$Root/seed' add -A
git -C '$Root/seed' -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m seed
git -C '$Root/seed' push -q '$Root/remote.git' main
git clone -q '$Root/remote.git' '$Root/checkout'
"@
        return $Root
    }
}

Describe 'shared checkout helpers' {
    It 'are the same functions in both installers' {
        # Each installer must run alone from a one-line download, so the helpers
        # are duplicated by necessity; this keeps the copies from drifting.
        foreach ($name in $script:SharedHelpers) {
            Assert-Equal -Expected $script:Bodies['install/ubuntu.kvm.sh'][$name] -Actual $script:Bodies['install/macos.utm.sh'][$name] `
                "$name differs between the macOS and Ubuntu installers"
        }
    }
}

Describe 'the installers route through the shared helpers' {
    BeforeAll {
        # Installer text with the shared helper bodies and every comment line
        # removed, so only the code that calls them is left to inspect.
        function Get-CallerText {
            param([Parameter(Mandatory)][string]$Installer)
            $text = $script:Texts[$Installer]
            foreach ($name in $script:SharedHelpers) { $text = $text.Replace($script:Bodies[$Installer][$name], '') }
            return (($text -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        }
    }
    It 'read group membership only through group_names' {
        # A bare id in a pipeline is what pipefail turns into a wrong answer.
        foreach ($installer in $script:Texts.Keys) {
            $callers = Get-CallerText -Installer $installer
            Assert-True ($callers -notmatch '\bid\s+-(nG|Gn)\b') "$installer reads groups with a bare id outside group_names"
            Assert-Match 'group_names \| grep -x' $callers "$installer does not use group_names for its elevation check"
        }
        $ubuntu = Get-CallerText -Installer 'install/ubuntu.kvm.sh'
        Assert-Match 'group_names "\$USER" \| grep -x "\$grp" >/dev/null' $ubuntu 'the group-add loop uses group_names'
        Assert-Match 'ACTIVE_GROUPS=\$\(group_names\)' $ubuntu 'the relog hint uses group_names'
    }
    It 're-clone and rebuild the checkout only through the helpers' {
        foreach ($installer in $script:Texts.Keys) {
            $callers = Get-CallerText -Installer $installer
            Assert-Match 'YURUNA_BACKUP_DIR="\$\(unique_backup_path "\$YURUNA_DIR"\)"' $callers "$installer names its backup without unique_backup_path"
            Assert-Match 'reclone_checkout "\$YURUNA_BACKUP_DIR" "\$reclone_remote"' $callers "$installer re-clones without reclone_checkout"
            Assert-True ($callers -notmatch 'git clone --branch "\$YURUNA_BRANCH" "\$reclone_remote"') "$installer still re-clones inline"
            Assert-Match '(?m)^\s*renormalize_checkout\s*$' $callers "$installer rebuilds line endings without renormalize_checkout"
            Assert-True ($callers -notmatch 'rm -r --cached') "$installer still runs rm --cached outside renormalize_checkout"
        }
    }
}

Describe 'unique_backup_path' {
    It 'never names a path that already exists' {
        $root = Join-Path $TestDrive 'backup-names'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $r = Invoke-HelperShell -Body @"
first="`$(unique_backup_path '$root/yuruna')"; mkdir -p "`$first"
second="`$(unique_backup_path '$root/yuruna')"; mkdir -p "`$second"
third="`$(unique_backup_path '$root/yuruna')"
echo "FIRST `$first"; echo "SECOND `$second"; echo "THIRD `$third"
[[ ! -e "`$third" ]] && echo THIRD-FREE
"@
        $lines = @{}
        foreach ($line in ($r.Output -split "`n")) { if ($line -match '^(FIRST|SECOND|THIRD) (.+)$') { $lines[$Matches[1]] = $Matches[2] } }
        Assert-Match ([regex]::Escape("$root/yuruna.backup.") + '\d{4}-\d{2}-\d{2}\.\d{2}-\d{2}-\d{2}') $lines['FIRST'] 'the name carries the date to the second'
        Assert-True ($lines['FIRST'] -ne $lines['SECOND'] -and $lines['SECOND'] -ne $lines['THIRD']) 'each call names a fresh path'
        Assert-Match 'THIRD-FREE' $r.Output 'the path returned does not exist yet'
    }
}

Describe 'group_names' {
    It 'keeps the names id printed when one group has no name' {
        # A group deleted mid-session, or a directory group that does not
        # resolve: id prints what it can and exits 1.
        $r = Invoke-HelperShell -Body @'
id() { echo 'ytest sudo 54321'; echo 'id: cannot find name for group ID 54321' >&2; return 1; }
if group_names | grep -xE 'sudo|wheel' >/dev/null; then echo IN-SUDO; else echo NOT-IN-SUDO; fi
groups="$(group_names)"
echo "LINES $(printf '%s\n' "$groups" | wc -l)"
'@
        Assert-Match 'IN-SUDO' $r.Output 'a session in the sudo group is recognized despite the unnamed group'
        Assert-True ($r.Output -notmatch 'NOT-IN-SUDO') 'the unnamed group must not decide the answer'
        Assert-Match 'LINES 3' $r.Output 'every printed name is kept, one per line'
        Assert-True ($r.Output -notmatch 'ERR-TRAP-FIRED') 'the inherited ERR trap does not fire'
        Assert-True ($r.Output -notmatch 'cannot find name') 'id''s complaint stays off the terminal'
    }
    It 'asks about a named user when given one' {
        $r = Invoke-HelperShell -Body @'
id() { printf 'ARGS:%s\n' "$*" >&2; echo 'libvirt kvm'; }
group_names someone | grep -x kvm >/dev/null && echo HAS-KVM
'@
        Assert-Match 'HAS-KVM' $r.Output 'the named user''s groups are read'
    }
}

Describe 'reclone_checkout' {
    It 'puts the moved checkout back when the clone cannot finish' {
        $root = New-GitFixture -Root (Join-Path $TestDrive 'reclone-fail')
        $r = Invoke-HelperShell -Body @"
YURUNA_DIR='$root/checkout'; YURUNA_BRANCH='2099.01.01'
YURUNA_BACKUP_CREATED='$root/checkout.backup'
mv '$root/checkout' '$root/checkout.backup'
reclone_checkout '$root/checkout.backup' '$root/remote.git'
echo "AFTER backup-created=[`$YURUNA_BACKUP_CREATED] issues=`${#YURUNA_ISSUES[@]}"
"@
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'checkout/marker.txt')) 'the previous checkout is back where the run expects it'
        Assert-False (Test-Path -LiteralPath (Join-Path $root 'checkout.backup')) 'nothing is left behind as a backup'
        Assert-Match 'AFTER backup-created=\[\] issues=1' $r.Output 'no backup notice is promised, and the failure is recorded once'
        Assert-Match "ISSUE Re-cloning from .*remote\.git \('2099\.01\.01'\) failed" $r.Output 'the issue names the remote and the ref'
        Assert-True ($r.Output -notmatch 'ERR-TRAP-FIRED|DIE') 'the run continues'
    }
    It 'clones normally when it can, keeping the backup for the notice' {
        $root = New-GitFixture -Root (Join-Path $TestDrive 'reclone-ok')
        $r = Invoke-HelperShell -Body @"
YURUNA_DIR='$root/checkout'; YURUNA_BRANCH='main'
YURUNA_BACKUP_CREATED='$root/checkout.backup'
mv '$root/checkout' '$root/checkout.backup'
reclone_checkout '$root/checkout.backup' '$root/remote.git'
echo "AFTER backup-created=[`$YURUNA_BACKUP_CREATED]"
"@
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'checkout/.git')) 'a fresh clone is in place'
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'checkout.backup/marker.txt')) 'the moved checkout stays as the backup'
        Assert-Match ([regex]::Escape("AFTER backup-created=[$root/checkout.backup]")) $r.Output 'the backup notice still has its path'
        Assert-True ($r.Output -notmatch 'ISSUE|ERR-TRAP-FIRED') 'a clone that works reports nothing'
    }
}

Describe 'reclone_checkout put-back' {
    It 'refuses to put the checkout back into a path that is still occupied' {
        # mv onto an existing directory would move the checkout inside it.
        $root = New-GitFixture -Root (Join-Path $TestDrive 'reclone-occupied')
        $r = Invoke-HelperShell -Body @"
YURUNA_DIR='$root/checkout'; YURUNA_BRANCH='2099.01.01'; YURUNA_BACKUP_CREATED='$root/checkout.backup'
mv '$root/checkout' '$root/checkout.backup'
rm() { if [[ "`$*" == *'$root/checkout'* && "`$*" != *backup* ]]; then return 1; fi; command rm "`$@"; }
git() { if [[ "`$1" == clone ]]; then mkdir -p '$root/checkout/partial'; return 128; fi; command git "`$@"; }
reclone_checkout '$root/checkout.backup' '$root/remote.git'
echo SHOULD-NOT-REACH
"@
        Assert-Match 'DIE Re-cloning from .* failed and the previous checkout could not be put back' $r.Output 'the run stops and says where the checkout is'
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'checkout.backup/marker.txt')) 'the moved checkout is still intact at its backup path'
        Assert-False (Test-Path -LiteralPath (Join-Path $root 'checkout/checkout.backup')) 'it was not moved inside the occupied path'
    }
}

Describe 'renormalize_checkout' {
    It 'rebuilds a clean checkout' {
        $root = New-GitFixture -Root (Join-Path $TestDrive 'renorm-ok')
        $r = Invoke-HelperShell -Body "YURUNA_DIR='$root/checkout'`nrenormalize_checkout"
        Assert-Match 'Working tree rebuilt under current \.gitattributes' $r.Output 'the rebuild runs'
        Assert-True ($r.Output -notmatch 'ISSUE|ERR-TRAP-FIRED') 'a clean rebuild reports nothing'
    }
    It 'records a held index lock and carries on with the index intact' {
        # A crashed git leaves .git/index.lock behind; the rebuild cannot take it.
        $root = New-GitFixture -Root (Join-Path $TestDrive 'renorm-lock')
        New-Item -ItemType File -Path (Join-Path $root 'checkout/.git/index.lock') -Force | Out-Null
        $r = Invoke-HelperShell -Body "YURUNA_DIR='$root/checkout'`nrenormalize_checkout`necho CONTINUED`nrm -f '$root/checkout/.git/index.lock'`ngit -C '$root/checkout' status --porcelain | wc -l | sed 's/^/STATUS-LINES /'"
        Assert-Match 'ISSUE Could not rebuild .* under \.gitattributes' $r.Output 'the failure reaches the closing summary'
        Assert-Match "reset --hard HEAD" $r.Output 'the operator is given the command that finishes the job'
        Assert-Match 'CONTINUED' $r.Output 'the run goes on'
        Assert-Match 'STATUS-LINES 0' $r.Output 'nothing is left staged or deleted'
        Assert-True ($r.Output -notmatch 'ERR-TRAP-FIRED') 'the inherited ERR trap does not fire'
    }
    It 'carries on past a held config lock' {
        # A crashed git can leave .git/config.lock as easily as index.lock.
        $root = New-GitFixture -Root (Join-Path $TestDrive 'renorm-config-lock')
        New-Item -ItemType File -Path (Join-Path $root 'checkout/.git/config.lock') -Force | Out-Null
        $r = Invoke-HelperShell -Body "YURUNA_DIR='$root/checkout'`nrenormalize_checkout`necho CONTINUED"
        Assert-Match 'WARN\s+could not set core\.autocrlf' $r.Output 'the failed config write is reported'
        Assert-Match 'CONTINUED' $r.Output 'the run goes on'
        Assert-True ($r.Output -notmatch 'ERR-TRAP-FIRED') 'the inherited ERR trap does not fire'
    }
    It 'puts the index back when the reset fails after rm --cached emptied it' {
        # The race: another git takes the lock between the two steps.
        $root = New-GitFixture -Root (Join-Path $TestDrive 'renorm-race')
        $r = Invoke-HelperShell -Body @"
YURUNA_DIR='$root/checkout'
git() { if [[ " `$* " == *' reset --hard '* ]]; then echo 'fatal: Unable to create index.lock: File exists' >&2; return 128; fi; command git "`$@"; }
renormalize_checkout
echo CONTINUED
command git -C '$root/checkout' status --porcelain | wc -l | sed 's/^/STATUS-LINES /'
"@
        Assert-Match 'ISSUE Could not rebuild' $r.Output 'the failed reset is recorded'
        Assert-Match 'STATUS-LINES 0' $r.Output 'the emptied index is restored from HEAD, so nothing reads as deleted'
        Assert-Match 'CONTINUED' $r.Output 'the run goes on'
    }
}

Describe 'installer outcome record' -Skip:$IsWindows {
    # Each installer ends with one JSON record of its outcome, so a caller reads
    # it instead of parsing the closing text. The bash installers carry the
    # writer word for word; the Windows installer writes the same fields.
    BeforeAll {
        $script:OutcomeFunctions = @('yuruna_json_string', 'write_install_result')
        $script:OutcomeBodies = @{}
        foreach ($installer in @('install/ubuntu.kvm.sh', 'install/macos.utm.sh')) {
            $script:OutcomeBodies[$installer] = ($script:OutcomeFunctions | ForEach-Object { Get-YurunaTestShellFunction -Text $script:Texts[$installer] -Name $_ }) -join "`n"
        }
        function Invoke-OutcomeShell {
            param([int]$Code, [string[]]$Issue = @(), [string]$Installer = 'ubuntu.kvm')
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'state'), (Join-Path $root 'checkout'), (Join-Path $root 'logs') -Force
            Set-Content -LiteralPath (Join-Path $root 'checkout/VERSION') -Value '2026.10.31'
            $issueLines = ($Issue | ForEach-Object { "YURUNA_ISSUES+=('" + $_.Replace("'", "'\''") + "')" }) -join "`n"
            $body = @(
                'set -euo pipefail', 'YURUNA_ISSUES=()', $issueLines,
                "XDG_STATE_HOME='$root/state'; YURUNA_DIR='$root/checkout'; YURUNA_INSTALL_LOG='$root/logs/ubuntu.kvm.install.1.log'",
                '_yuruna_step="Installing libvirt"',
                $script:OutcomeBodies['install/ubuntu.kvm.sh'],
                "write_install_result $Code '$Installer'; echo rc=`$?"
            ) -join "`n"
            $run = Invoke-YurunaTestShell -Body $body
            $file = Join-Path $root 'state/yuruna/install-result.json'
            return @{ Run = $run; File = $file; Root = $root }
        }
    }

    It 'is the same writer in both bash installers, called from the EXIT handler' {
        $script:OutcomeBodies['install/macos.utm.sh'] | Should -BeExactly $script:OutcomeBodies['install/ubuntu.kvm.sh']
        $script:Texts['install/ubuntu.kvm.sh'] | Should -Match 'write_install_result "\$rc" "ubuntu\.kvm"\r?\n  _yuruna_flush_log'
        $script:Texts['install/macos.utm.sh'] | Should -Match 'write_install_result "\$rc" "macos\.utm"\r?\n  _yuruna_flush_log'
    }

    It 'records a clean run as succeeded, beside the log too' {
        $r = Invoke-OutcomeShell -Code 0
        $r.Run.Output | Should -Match 'rc=0'
        $record = Get-Content -LiteralPath $r.File -Raw | ConvertFrom-Json
        $record.outcome | Should -Be 'succeeded'
        $record.exitCode | Should -Be 0
        $record.version | Should -Be '2026.10.31'
        $record.step | Should -Be 'Installing libvirt'
        @($record.issues).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $r.Root 'logs/ubuntu.kvm.install.1.result.json') | Should -BeTrue
    }

    It 'carries every deferred issue verbatim, quotes and backslashes included' {
        $issue = 'path C:\yuruna has a "quote" & a tab' + "`t" + 'here'
        $r = Invoke-OutcomeShell -Code 0 -Issue @('first issue', $issue)
        $record = Get-Content -LiteralPath $r.File -Raw | ConvertFrom-Json
        $record.outcome | Should -Be 'succeeded-with-issues'
        @($record.issues) | Should -Be @('first issue', $issue)
    }

    It 'records a failed run with its exit code' {
        $r = Invoke-OutcomeShell -Code 3 -Installer 'macos.utm'
        $r.Run.Output | Should -Match 'rc=0' -Because 'the writer never changes the exit status of the trap'
        $record = Get-Content -LiteralPath $r.File -Raw | ConvertFrom-Json
        $record.outcome | Should -Be 'failed'
        $record.exitCode | Should -Be 3
        $record.installer | Should -Be 'macos.utm'
    }

    It 'has the Windows installer write the same record at its end and from its trap' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Raw
        $text | Should -Match 'Write-InstallResult\r?\n# Close the transcript'
        $text | Should -Match "trap \{\r?\n    Write-InstallResult -Outcome 'failed'\r?\n    break\r?\n\}"
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-InstallResult' }, $true)
        $root = Join-Path $TestDrive 'win'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'checkout'), (Join-Path $root 'local') -Force
        Set-Content -LiteralPath (Join-Path $root 'checkout/VERSION') -Value '2026.10.31'
        $saved = Save-YurunaTestEnvironment -Name 'LOCALAPPDATA'
        try {
            $env:LOCALAPPDATA = Join-Path $root 'local'
            $record = & ([scriptblock]::Create(@"
`$YurunaDir = '$root/checkout'; `$LogPath = '$root/windows.hyper-v.install.1.log'
`$script:RestartNeeded = `$false; `$script:InstallSucceeded = `$true
`$script:YurunaIssue = [System.Collections.Generic.List[string]]::new(); `$script:YurunaIssue.Add('winget "x" failed')
$($fn.Extent.Text)
Write-InstallResult
Get-Content -LiteralPath (Join-Path `$env:LOCALAPPDATA 'yuruna/install-result.json') -Raw | ConvertFrom-Json
"@))
        } finally { Restore-YurunaTestEnvironment -Saved $saved }
        $record.installer | Should -Be 'windows.hyper-v'
        $record.outcome | Should -Be 'succeeded-with-issues'
        @($record.issues) | Should -Be @('winget "x" failed')
        Test-Path -LiteralPath (Join-Path $root 'windows.hyper-v.install.1.result.json') | Should -BeTrue
    }
}

Describe 'Windows installer elevation runs only a checked, administrator-only copy' {
    # The elevated stage must not execute a file in a folder the unelevated
    # account can write. It starts from an encoded command that copies the
    # installer into a folder only Administrators and SYSTEM can write, checks
    # the copy against the hash taken at startup, and runs the copy.
    BeforeAll {
        $script:WinText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Raw
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:WinText, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ElevatedInstallerCommand' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        function Get-ElevatedScript { param($Source, $Sha, $Parameter) [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String((New-ElevatedInstallerCommand -SourcePath $Source -Sha256 $Sha -Parameter $Parameter))) }
        # The Windows-only ACL calls are the one part replaced to run the rest here.
        function Invoke-ElevatedScript {
            param([string]$Text, [string]$ProgramData)
            $portable = [regex]::Replace($Text, '(?ms)^\$security = New-Object.*?^if \(\$PSVersionTable\.PSVersion\.Major -ge 6\)[^\n]*$', '[void][System.IO.Directory]::CreateDirectory($dir)')
            $file = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
            Set-Content -LiteralPath $file -Value ("function Start-Sleep { }`n" + $portable)
            $saved = Save-YurunaTestEnvironment -Name 'ProgramData', 'NO_COLOR'
            try {
                $env:ProgramData = $ProgramData; $env:NO_COLOR = '1'
                $output = & ([Environment]::ProcessPath) -NoProfile -File $file 2>&1
                return @{ Code = $LASTEXITCODE; Output = (($output -join "`n") -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '') }
            } finally { Restore-YurunaTestEnvironment -Saved $saved }
        }
    }

    It 'elevates through the encoded command, never through -File on the original path' {
        $block = $script:WinText.Substring($script:WinText.IndexOf("if (-not `$isAdmin) {"))
        $block = $block.Substring(0, $block.IndexOf('Start-Process'))
        $block | Should -Match "'-EncodedCommand', \`$encoded"
        $block | Should -Not -Match "'-File', `"``\`"\`$PSCommandPath"
        $script:WinText.IndexOf('$script:InstallerSelfSha256 = (Get-FileHash') | Should -BeLessThan $script:WinText.IndexOf('# --- REGION: Single-fetch materialization')
    }

    It 'always busts the CDN cache when it materializes the installer' {
        $gate = $script:WinText.Substring($script:WinText.IndexOf("if (-not `$PSCommandPath) {"))
        $gate = $gate.Substring(0, $gate.IndexOf('Invoke-RestMethod'))
        $gate | Should -Match ([regex]::Escape("`$installerUrl += '?nocache=' + [uri]::EscapeDataString(`$cacheBuster)"))
        $gate | Should -Not -Match 'if \(\$env:YurunaCacheContent\) \{ \$installerUrl \+='
    }

    It 'locks the copy to Administrators and SYSTEM and quotes every value' {
        $text = Get-ElevatedScript -Source "C:\Users\o'brien\x.ps1" -Sha ('a' * 64) -Parameter ([ordered]@{ SkipPreflight = $true; LogPath = "C:\logs\it's.log" })
        $errors = $null; [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors | Should -HaveCount 0
        $text | Should -Match ([regex]::Escape("`$source = 'C:\Users\o''brien\x.ps1'"))
        $text | Should -Match ([regex]::Escape("LogPath = 'C:\logs\it''s.log'"))
        $text | Should -Match ([regex]::Escape("SkipPreflight = `$true"))
        $text | Should -Match ([regex]::Escape("SetAccessRuleProtection(`$true, `$false)"))
        $text | Should -Match ([regex]::Escape("@('S-1-5-32-544', 'S-1-5-18')"))
        $text.IndexOf('if ($actual -ne $expected)') | Should -BeLessThan $text.IndexOf('& $target @parameters')
    }

    It 'runs the copy with the forwarded parameters when the installer is unchanged' {
        $source = Join-Path $TestDrive 'installer-ok.ps1'
        $record = Join-Path $TestDrive 'ran.json'
        Set-Content -LiteralPath $source -Value "param([switch]`$SkipPreflight, [string]`$LogPath) @{ skip = [bool]`$SkipPreflight; log = `$LogPath; path = `$PSCommandPath } | ConvertTo-Json | Set-Content -LiteralPath '$record'"
        $sha = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $programData = Join-Path $TestDrive 'pd-ok'; $null = New-Item -ItemType Directory -Path $programData
        $r = Invoke-ElevatedScript -Text (Get-ElevatedScript -Source $source -Sha $sha -Parameter ([ordered]@{ SkipPreflight = $true; LogPath = "/tmp/it's.log" })) -ProgramData $programData
        $r.Code | Should -Be 0
        $ran = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
        $ran.skip | Should -BeTrue
        $ran.log | Should -Be "/tmp/it's.log"
        $ran.path | Should -BeLike (Join-Path $programData 'yuruna*')
        @(Get-ChildItem -LiteralPath (Join-Path $programData 'yuruna') -Force) | Should -HaveCount 0 -Because 'the copy is removed after the run'
    }

    It 'refuses to run an installer that changed after its hash was taken' {
        $source = Join-Path $TestDrive 'installer-swapped.ps1'
        $record = Join-Path $TestDrive 'swapped-ran.txt'
        Set-Content -LiteralPath $source -Value 'Write-Output original'
        $sha = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath $source -Value "Set-Content -LiteralPath '$record' -Value swapped"
        $programData = Join-Path $TestDrive 'pd-swap'; $null = New-Item -ItemType Directory -Path $programData
        $r = Invoke-ElevatedScript -Text (Get-ElevatedScript -Source $source -Sha $sha -Parameter ([ordered]@{ SkipPreflight = $true })) -ProgramData $programData
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'changed after it started'
        Test-Path -LiteralPath $record | Should -BeFalse
    }
}
