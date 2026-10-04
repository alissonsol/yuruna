<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42df5581-572e-4f0e-9e2c-5cfd797e9fbf
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest kubernetes certificate password pester
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
    Pins how the guest k8s provisioning scripts create the HTTPS development
    certificate: a random PFX password that only an owner-only sidecar file keeps.
.DESCRIPTION
    The Ubuntu 24.04, Ubuntu 26.04 and Windows 11 k8s scripts export
    ~/.aspnet/https/aspnetapp.pfx. The examples open that file with the password in
    ASPNETCORE_Kestrel__Certificates__Default__Password or, when the variable is
    unset, with the one line in aspnetapp.pfx.password beside it. Three properties
    make that safe, and each fails quietly if it is lost:

      * The password is random per run. A fixed one lets any local account that can
        read the PFX open its private key, and the PFX is readable by design.
      * The password never reaches a command line, the console, or a trace. A
        command line is visible to every local user in the process list, and
        fetch-and-execute runs a guest script under xtrace and keeps the trace with
        the step's command profile.
      * The sidecar is created owner-only from the start (mode 600, or an ACL
        limited to the current user), so it is never readable by anyone else even
        for an instant.

    The static cases read the shipped scripts. The behavior cases run the Ubuntu
    certificate region itself under bash with a temporary HOME and real openssl,
    and, on Windows only, the Windows region under both Windows PowerShell and
    PowerShell 7 with openssl standing in for mkcert. A behavior case is skipped,
    with its reason, only when bash or openssl is missing; the Windows cases are
    defined only on Windows, so no other platform reports them as skipped.

    Should assertions only.
#>

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$script:guestScripts = @{
    ubuntu24  = Join-Path $repoRoot 'guest/ubuntu.server.24/ubuntu.server.24.k8s.sh'
    ubuntu26  = Join-Path $repoRoot 'guest/ubuntu.server.26/ubuntu.server.26.k8s.sh'
    windows11 = Join-Path $repoRoot 'guest/windows.11/windows.11.k8s.ps1'
}
$script:regionMarker = '# --- REGION: Create the HTTPS development certificate'
$script:windowsRegionEnd = 'Write-Output "<<< HTTPS development certificate complete."'

function Get-RegionText {
    <#
        The text from the certificate region marker to the line before the next
        region marker. With -Through, to and including the first line that holds
        that text: the Windows region goes on to trust the mkcert root CA, which
        no test may run.
    #>
    param([string]$Path, [string]$Through)
    $collected = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in ([IO.File]::ReadAllText($Path) -split "`r?`n")) {
        if (-not $inside) {
            if ($line.StartsWith($script:regionMarker)) { $inside = $true; $collected.Add($line) }
            continue
        }
        if ($Through) {
            $collected.Add($line)
            if ($line.Contains($Through)) { break }
        } else {
            if ($line.StartsWith('# --- REGION:')) { break }
            $collected.Add($line)
        }
    }
    if ($collected.Count -eq 0) { throw "No '$($script:regionMarker)' region in $Path" }
    return ($collected -join "`n")
}

function Find-GitUsrBin {
    <#
        Git for Windows keeps its POSIX userland in usr/bin. Git\bin\bash.exe is a
        wrapper that reorders PATH, so the real bash and the openssl beside it
        are taken from usr/bin explicitly. Windows only; elsewhere the PATH is trusted.
    #>
    if (-not $IsWindows) { return $null }
    $candidates = [System.Collections.Generic.List[string]]::new()
    $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $directory = Split-Path -Parent $git.Source
        for ($level = 0; $level -lt 3 -and $directory; $level++) {
            $candidates.Add((Join-Path $directory 'usr/bin'))
            $directory = Split-Path -Parent $directory
        }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates.Add((Join-Path $base 'Git/usr/bin')) }
    }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs/Git/usr/bin')) }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'bash.exe') -PathType Leaf) { return $candidate }
    }
    return $null
}

$script:usrBin = Find-GitUsrBin
$script:bash = if ($IsWindows) {
    if ($script:usrBin) { Join-Path $script:usrBin 'bash.exe' }
} else {
    (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
$script:openssl = if ($IsWindows -and $script:usrBin -and (Test-Path -LiteralPath (Join-Path $script:usrBin 'openssl.exe') -PathType Leaf)) {
    Join-Path $script:usrBin 'openssl.exe'
} else {
    (Get-Command openssl -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
$script:toolPath = if ($script:usrBin) { $script:usrBin + [IO.Path]::PathSeparator + $env:PATH } else { $env:PATH }
$script:bashSkip = if (-not $script:bash) { 'bash was not found (on Windows it is Git for Windows usr\bin\bash.exe)' }
    elseif (-not $script:openssl) { 'openssl was not found' }

function Get-PrintableText {
    <#
        Text for a failure message: control characters are replaced, because a raw
        escape byte (the scripts color their headings) makes the NUnit result file
        unreadable, and the length is capped.
    #>
    param([string]$Text)
    $clean = [regex]::Replace([string]$Text, '[^\x09\x0A\x0D\x20-\x7E]', '?')
    if ($clean.Length -gt 1500) { return $clean.Substring(0, 1500) + '...' }
    return $clean
}

function Invoke-ChildProcess {
    <# Runs a program with extra environment variables and returns its exit code and both output streams. #>
    param([string]$FileName, [string[]]$Arguments, [hashtable]$Environment, [int]$TimeoutSeconds = 240)
    $info = [Diagnostics.ProcessStartInfo]::new($FileName)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in $Environment.Keys) { $info.Environment[$name] = [string]$Environment[$name] }
    $process = [Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { Write-Verbose "kill: $($_.Exception.Message)" }
        throw "$FileName did not finish within $TimeoutSeconds seconds"
    }
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Result; Error = $errors.Result }
}

function Test-PfxOpensWithOpenssl {
    <# True when openssl accepts the password for the PFX. The password travels in the environment. #>
    param([string]$Path, [string]$Unlock)
    $result = Invoke-ChildProcess -FileName $script:openssl -Arguments @('pkcs12', '-in', $Path, '-noout', '-passin', 'env:YURUNA_TEST_PFX_UNLOCK') `
        -Environment @{ YURUNA_TEST_PFX_UNLOCK = $Unlock; PATH = $script:toolPath }
    return ($result.ExitCode -eq 0)
}

function Test-PfxOpensWithDotNet {
    <# True when .NET loads the PFX with the password and finds a private key, the way the examples open it. #>
    param([string]$Path, [string]$Unlock)
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
    try {
        $certificate = if ($loader) { $loader::LoadPkcs12FromFile($Path, $Unlock, $flags) }
        else { [Security.Cryptography.X509Certificates.X509Certificate2]::new($Path, $Unlock, $flags) }
        $usable = $certificate.HasPrivateKey -and $certificate.Subject -eq 'CN=localhost'
        $certificate.Dispose()
        return $usable
    } catch {
        return $false
    }
}
}

Describe 'The guest k8s scripts carry no fixed certificate password' {
    It 'has no literal password or openssl password argument in <Name>' -ForEach @(
        @{ Name = 'ubuntu.server.24.k8s.sh'; Key = 'ubuntu24' }
        @{ Name = 'ubuntu.server.26.k8s.sh'; Key = 'ubuntu26' }
        @{ Name = 'windows.11.k8s.ps1'; Key = 'windows11' }
    ) {
        # Booleans, not -Not -Match: a failing -Match would print the whole script into the result file.
        $text = [IO.File]::ReadAllText($script:guestScripts[$Key])
        [regex]::IsMatch($text, 'pass:password') | Should -BeFalse -Because 'the literal openssl password argument is gone'
        [regex]::IsMatch($text, '(?i)-password\s+pass:') | Should -BeFalse -Because 'no password is given on an openssl command line'
        [regex]::IsMatch($text, '(?i)[''"]password[''"]') | Should -BeFalse -Because 'the literal password is not a quoted string in the script'
    }
    It 'passes no openssl password on a command line in <Name>' -ForEach @(
        @{ Name = 'ubuntu.server.24.k8s.sh'; Key = 'ubuntu24' }
        @{ Name = 'ubuntu.server.26.k8s.sh'; Key = 'ubuntu26' }
    ) {
        $text = [IO.File]::ReadAllText($script:guestScripts[$Key])
        [regex]::IsMatch($text, '\bpass:') | Should -BeFalse -Because 'pass: puts the value on the command line'
        [regex]::IsMatch($text, '(?i)-pass(in|out)?\s+(?!env:|file:|fd:|stdin)\S') | Should -BeFalse -Because 'only env:, file:, fd: and stdin sources keep it off the command line'
    }
}

Describe 'The Ubuntu certificate region' {
    BeforeAll {
        $script:region24 = Get-RegionText -Path $script:guestScripts.ubuntu24
        $script:region26 = Get-RegionText -Path $script:guestScripts.ubuntu26
    }
    It 'is the same in the 24.04 and 26.04 scripts' {
        $script:region26 | Should -BeExactly $script:region24
    }
    It 'draws a random 32-byte password and hands it to openssl through the environment of that one command' {
        $script:region24 | Should -Match '(?m)^PFX_PASSWORD="\$\(openssl rand -hex 32\)"$'
        $script:region24 | Should -Match '(?m)^PFX_PASSWORD="\$PFX_PASSWORD" openssl pkcs12 -export .* -passout env:PFX_PASSWORD$'
        $script:region24 | Should -Not -Match '(?m)^export PFX_PASSWORD'
    }
    It 'writes the sidecar beside the PFX under umask 077 and replaces any earlier file' {
        $script:region24 | Should -Match '(?m)^rm -f "\$PFX_FILE\.password"$'
        $script:region24 | Should -Match '(?m)^\(umask 077; printf ''%s\\n'' "\$PFX_PASSWORD" > "\$PFX_FILE\.password"\)$'
        $script:region24 | Should -Match '(?m)^PFX_FILE="\$PFX_DIR/aspnetapp\.pfx"$'
    }
    It 'gives the real user the sidecar with the rest of the directory and removes the key and certificate' {
        $script:region24 | Should -Match '(?m)^chown -R "\$REAL_USER:\$REAL_USER" "\$PFX_DIR"$'
        $script:region24 | Should -Match '(?m)^rm -f "\$PFX_DIR/aspnetapp\.key" "\$PFX_DIR/aspnetapp\.crt"$'
    }
    It 'pauses xtrace around the only lines that hold the password' {
        $region = $script:region24
        $off = $region.IndexOf("`nset +x`n")
        $generate = $region.IndexOf('openssl rand -hex 32')
        $forget = $region.IndexOf('unset PFX_PASSWORD')
        $restore = $region.IndexOf('set -x')
        $off | Should -BeGreaterThan 0
        $generate | Should -BeGreaterThan $off
        $forget | Should -BeGreaterThan $generate
        $restore | Should -BeGreaterThan $forget
        $region | Should -Match '(?m)^case \$- in \*x\*\) PFX_XTRACE=1 ;; \*\) PFX_XTRACE=0 ;; esac$'
    }
    It 'prints the password only into the sidecar' {
        foreach ($line in ($script:region24 -split "`n")) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '\b(echo|printf)\b' -and $line -match 'PFX_PASSWORD') {
                $line | Should -Match '> "\$PFX_FILE\.password"' -Because 'the only command that outputs the password writes it to the sidecar'
            }
        }
    }
    It 'is pure ASCII with LF line ends and no byte-order mark in <Name>' -ForEach @(
        @{ Name = 'ubuntu.server.24.k8s.sh'; Key = 'ubuntu24' }
        @{ Name = 'ubuntu.server.26.k8s.sh'; Key = 'ubuntu26' }
    ) {
        $bytes = [IO.File]::ReadAllBytes($script:guestScripts[$Key])
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because 'the guest reads these bytes through a console and a hash'
        @($bytes | Where-Object { $_ -eq 13 }).Count | Should -Be 0 -Because 'a carriage return would end every bash word'
    }
}

Describe 'The Windows certificate region' {
    BeforeAll {
        $script:windowsRegion = Get-RegionText -Path $script:guestScripts.windows11 -Through $script:windowsRegionEnd
    }
    It 'draws the password from the cryptographic generator inside the pwsh child' {
        $script:windowsRegion | Should -Match 'RandomNumberGenerator\]::GetBytes\(32\)'
        $script:windowsRegion | Should -Match 'ToHexString\(.*\)\.ToLowerInvariant\(\)'
        $script:windowsRegion | Should -Match 'Export\(\[System\.Security\.Cryptography\.X509Certificates\.X509ContentType\]::Pfx, `\$password\)'
    }
    It 'writes the sidecar beside the PFX and limits it to the current user by SID' {
        $script:windowsRegion | Should -Match '\$pfxPasswordFile = "\$pfxFile\.password"'
        $script:windowsRegion | Should -Match 'SetAccessRuleProtection\(`\$true, `\$false\)'
        $script:windowsRegion | Should -Match 'WindowsIdentity\]::GetCurrent\(\)\.User'
        $script:windowsRegion | Should -Match 'Set-Acl -LiteralPath'
    }
    It 'restricts the file before the password is written to it' {
        $region = $script:windowsRegion
        $create = $region.IndexOf('New-Item -ItemType File')
        $restrict = $region.IndexOf('Set-Acl -LiteralPath')
        $write = $region.IndexOf('WriteAllText(')
        $create | Should -BeGreaterThan 0
        $restrict | Should -BeGreaterThan $create
        $write | Should -BeGreaterThan $restrict
    }
    It 'never writes the password to an output stream' {
        foreach ($line in ($script:windowsRegion -split "`n")) {
            $line | Should -Not -Match '(?i)(Write-(Output|Host|Information|Verbose|Debug|Warning|Error)|Out-Host|echo)\b.*\$password\b'
        }
    }
    It 'is pure ASCII with no byte-order mark' {
        $bytes = [IO.File]::ReadAllBytes($script:guestScripts.windows11)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
}

Describe 'The Ubuntu certificate region, run under bash' {
    BeforeAll {
        $script:bashRan = $false
        if ($script:bashSkip) { return }
        $script:work = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-k8s-cert-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:work -Force
        $realHome = Join-Path $script:work 'home'
        $null = New-Item -ItemType Directory -Path $realHome -Force
        $https = Join-Path $realHome '.aspnet/https'
        $pfx = Join-Path $https 'aspnetapp.pfx'
        $sidecar = "$pfx.password"
        $chownLog = Join-Path $script:work 'chown.log'

        # The script runs under set -euo pipefail. chown is replaced by a recorder: the test user
        # cannot hand files to another account, and a Windows userland has no such group.
        $prelude = @'
set -euo pipefail
chown() { printf '%s\n' "$*" >> "$CHOWN_LOG"; }
'@
        $driver = Join-Path $script:work 'region.sh'
        $script:bashRegion = Get-RegionText -Path $script:guestScripts.ubuntu24
        $driverText = ($prelude + "`n" + $script:bashRegion + "`n").Replace("`r`n", "`n")
        [IO.File]::WriteAllText($driver, $driverText, [Text.UTF8Encoding]::new($false))
        $posix = { param($path) $path.Replace('\', '/') }
        $environment = @{
            HOME = & $posix $realHome
            REAL_HOME = & $posix $realHome
            REAL_USER = 'guestuser'
            CHOWN_LOG = & $posix $chownLog
            PATH = $script:toolPath
        }

        $readState = {
            param($label, $run)
            $copy = Join-Path $script:work "$label.pfx"
            if (Test-Path -LiteralPath $pfx) { Copy-Item -LiteralPath $pfx -Destination $copy }
            [pscustomobject]@{
                Run = $run
                Listing = @(if (Test-Path -LiteralPath $https) { Get-ChildItem -LiteralPath $https -Force | ForEach-Object Name | Sort-Object })
                SidecarText = if (Test-Path -LiteralPath $sidecar) { [IO.File]::ReadAllText($sidecar) }
                Mode = if (-not $IsWindows -and (Test-Path -LiteralPath $sidecar)) { [int][IO.File]::GetUnixFileMode($sidecar) }
                PfxCopy = $copy
            }
        }

        # First run into an empty home.
        $script:first = & $readState 'first' (Invoke-ChildProcess -FileName $script:bash -Arguments @($driver) -Environment $environment)
        $script:chownCalls = @(if (Test-Path -LiteralPath $chownLog) { Get-Content -LiteralPath $chownLog })
        # Second run over the first one, under xtrace the way fetch-and-execute runs a guest script,
        # after loosening the sidecar: the run must replace it, not reuse its mode.
        if (-not $IsWindows -and (Test-Path -LiteralPath $sidecar)) { [IO.File]::SetUnixFileMode($sidecar, [IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead') }
        $script:second = & $readState 'second' (Invoke-ChildProcess -FileName $script:bash -Arguments @('-x', $driver) -Environment $environment)
        $script:bashRan = $true
    }
    AfterAll {
        if ($script:work -and (Test-Path -LiteralPath $script:work)) { Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'runs to completion' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        $script:first.Run.ExitCode | Should -Be 0 -Because (Get-PrintableText $script:first.Run.Error)
        $script:second.Run.ExitCode | Should -Be 0 -Because (Get-PrintableText $script:second.Run.Error)
    }
    It 'keeps the password in a sidecar of one line of 64 hexadecimal characters' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        $script:first.SidecarText | Should -Match '^[0-9a-f]{64}\n$'
    }
    It 'exports a PFX that opens with the sidecar password and not with a fixed one' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        $unlock = $script:first.SidecarText.TrimEnd("`n")
        Test-PfxOpensWithOpenssl -Path $script:first.PfxCopy -Unlock $unlock | Should -BeTrue
        Test-PfxOpensWithOpenssl -Path $script:first.PfxCopy -Unlock 'password' | Should -BeFalse
        Test-PfxOpensWithDotNet -Path $script:first.PfxCopy -Unlock $unlock | Should -BeTrue
        Test-PfxOpensWithDotNet -Path $script:first.PfxCopy -Unlock 'password' | Should -BeFalse
    }
    It 'leaves only the PFX and its sidecar: the key and certificate temp files are gone' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        ($script:first.Listing -join ',') | Should -Be 'aspnetapp.pfx,aspnetapp.pfx.password'
    }
    It 'creates the sidecar readable by its owner only' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        # The write is confined to a umask 077 subshell, so the file never exists with wider access.
        $script:bashRegion | Should -Match '\(umask 077; printf [^)]*> "\$PFX_FILE\.password"\)'
        # Only a POSIX userland has real modes: a Windows one reports an emulated mode, and the
        # Windows region case below checks the ACL instead.
        if (-not $IsWindows) { $script:first.Mode | Should -Be 384 -Because 'mode 600 from the start, under umask 077' }
    }
    It 'hands the certificate directory to the real user' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        $script:chownCalls.Count | Should -Be 1
        $script:chownCalls[0] | Should -Match '^-R guestuser:guestuser .*/\.aspnet/https$'
    }
    It 'prints the password nowhere on the console' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        $unlock = $script:first.SidecarText.TrimEnd("`n")
        $script:first.Run.Output.Contains($unlock) | Should -BeFalse -Because 'the console must not show the password'
        $script:first.Run.Error.Contains($unlock) | Should -BeFalse -Because 'standard error must not show the password'
    }
    It 'replaces the PFX and the sidecar together on a repeat run, and re-creates the sidecar owner-only' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        $old = $script:first.SidecarText.TrimEnd("`n")
        $new = $script:second.SidecarText.TrimEnd("`n")
        $new | Should -Match '^[0-9a-f]{64}$'
        $new | Should -Not -Be $old
        ($script:second.Listing -join ',') | Should -Be 'aspnetapp.pfx,aspnetapp.pfx.password'
        Test-PfxOpensWithOpenssl -Path $script:second.PfxCopy -Unlock $new | Should -BeTrue
        Test-PfxOpensWithOpenssl -Path $script:second.PfxCopy -Unlock $old | Should -BeFalse
        if (-not $IsWindows) { $script:second.Mode | Should -Be 384 }
    }
    It 'keeps the password out of an xtrace, which fetch-and-execute keeps with the step profile' {
        if (-not $script:bashRan) { Set-ItResult -Skipped -Because $script:bashSkip; return }
        $new = $script:second.SidecarText.TrimEnd("`n")
        $trace = $script:second.Run.Error
        [regex]::IsMatch($trace, '(?m)^\+ openssl req ') | Should -BeTrue -Because 'the trace was on before the password existed'
        [regex]::IsMatch($trace, '(?m)^\+ chown -R ') | Should -BeTrue -Because 'the trace was switched back on afterwards'
        $trace.Contains($new) | Should -BeFalse -Because 'the trace is kept with the step profile'
        $script:second.Run.Output.Contains($new) | Should -BeFalse -Because 'the console must not show the password'
    }
}

# Windows PowerShell and NTFS ACLs exist only on Windows, so these cases are defined only there:
# any other platform reports fewer tests, never a skipped one.
if ($IsWindows) {
    Describe 'The Windows certificate region, run with openssl standing in for mkcert' {
        BeforeAll {
            $script:windowsRuns = @{}
            $script:windowsSkip = if (-not $script:openssl) { 'openssl was not found to stand in for mkcert' }
            if ($script:windowsSkip) { return }
            $script:windowsWork = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-k8s-cert-win-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:windowsWork -Force

            # mkcert is replaced by a function that makes the same two PEM files with openssl.
            $stub = @(
                'function mkcert {'
                '    $ErrorActionPreference = ''Continue'''
                '    & $env:YURUNA_TEST_OPENSSL req -x509 -newkey rsa:2048 -nodes -keyout $args[1] -out $args[3] -days 2 -subj ''/CN=localhost'' 2>&1 | Out-Null'
                '}'
            ) -join "`n"
            $driver = Join-Path $script:windowsWork 'region.ps1'
            $region = Get-RegionText -Path $script:guestScripts.windows11 -Through $script:windowsRegionEnd
            [IO.File]::WriteAllText($driver, ($stub + "`n" + $region + "`n"), [Text.UTF8Encoding]::new($false))
            foreach ($shell in @('powershell.exe', 'pwsh')) {
                $command = Get-Command $shell -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $command) { continue }
                $profileDirectory = Join-Path $script:windowsWork ($shell -replace '\W', '-')
                $null = New-Item -ItemType Directory -Path $profileDirectory -Force
                $run = Invoke-ChildProcess -FileName $command.Source -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver) `
                    -Environment @{ USERPROFILE = $profileDirectory; YURUNA_TEST_OPENSSL = $script:openssl; PATH = $script:toolPath }
                $script:windowsRuns[$shell] = [pscustomobject]@{ Run = $run; Profile = $profileDirectory }
            }
        }
        AfterAll {
            if ($script:windowsWork -and (Test-Path -LiteralPath $script:windowsWork)) { Remove-Item -LiteralPath $script:windowsWork -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'creates a PFX that opens only with the sidecar password, under <Shell>' -ForEach @(@{ Shell = 'powershell.exe' }, @{ Shell = 'pwsh' }) {
            if ($script:windowsSkip) { Set-ItResult -Skipped -Because $script:windowsSkip; return }
            if (-not $script:windowsRuns.ContainsKey($Shell)) { Set-ItResult -Skipped -Because "$Shell was not found"; return }
            $state = $script:windowsRuns[$Shell]
            $state.Run.ExitCode | Should -Be 0 -Because (Get-PrintableText ($state.Run.Output + $state.Run.Error))
            $https = Join-Path $state.Profile '.aspnet/https'
            $pfx = Join-Path $https 'aspnetapp.pfx'
            $sidecar = "$pfx.password"
            (@(Get-ChildItem -LiteralPath $https -Force | ForEach-Object Name | Sort-Object) -join ',') | Should -Be 'aspnetapp.pfx,aspnetapp.pfx.password'
            $text = [IO.File]::ReadAllText($sidecar)
            $text | Should -Match '^[0-9a-f]{64}\n$'
            $unlock = $text.TrimEnd("`n")
            Test-PfxOpensWithDotNet -Path $pfx -Unlock $unlock | Should -BeTrue
            Test-PfxOpensWithDotNet -Path $pfx -Unlock 'password' | Should -BeFalse
            $state.Run.Output.Contains($unlock) | Should -BeFalse -Because 'the console must not show the password'
            $state.Run.Error.Contains($unlock) | Should -BeFalse -Because 'standard error must not show the password'
        }
        It 'limits the sidecar to the current user with no inherited access, under <Shell>' -ForEach @(@{ Shell = 'powershell.exe' }, @{ Shell = 'pwsh' }) {
            if ($script:windowsSkip) { Set-ItResult -Skipped -Because $script:windowsSkip; return }
            if (-not $script:windowsRuns.ContainsKey($Shell)) { Set-ItResult -Skipped -Because "$Shell was not found"; return }
            $sidecar = Join-Path $script:windowsRuns[$Shell].Profile '.aspnet/https/aspnetapp.pfx.password'
            $acl = Get-Acl -LiteralPath $sidecar
            $acl.AreAccessRulesProtected | Should -BeTrue
            $rules = @($acl.Access)
            $rules.Count | Should -Be 1
            $rules[0].IsInherited | Should -BeFalse
            $rules[0].AccessControlType | Should -Be ([Security.AccessControl.AccessControlType]::Allow)
            $rules[0].FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)
            $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value | Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        }
    }
}
