<#PSScriptInfo
.VERSION 2026.10.22
.GUID 424d8a56-b48d-45fb-82a4-dcd615a7bce8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Exercise shipping guest materialization over an authenticated disposable guest.
.DESCRIPTION
    Unix rows require a provisioned guest whose seeded host status service is
    unavailable; the driver measures that condition before executing the actual
    fetcher or materializer. Windows rows render the old or candidate seed and
    execute the candidate updater's complete framework block in a fresh guest
    directory, without running unrelated operating-system provisioning.
    Only public candidate bytes, fixture routing and seed coordinates are sent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('GM-GUEST-RAW-FALLBACK', 'GM-GUEST-TREE-FALLBACK',
        'GM-WIN-GUEST-OLD-SEED', 'GM-WIN-GUEST-NEW-SEED')][string]$Scenario,
    [Parameter(Mandatory)][string]$UpstreamsPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$FrameworkTree,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9.-]+$')][string]$MirrorAddress,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.@:-]+$')][string]$GuestHost,
    [Parameter(Mandatory)][string]$SshKeyPath,
    [string]$OldRoot,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$DisposableTarget
)
$ErrorActionPreference = 'Stop'
if (-not $DisposableTarget) { throw 'Guest drills require an explicitly disposable guest.' }
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$output = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw 'Guest evidence already exists; preserve prior observations.' }
$upstreams = Get-Content -Raw -LiteralPath $UpstreamsPath | ConvertFrom-Json -AsHashtable
$repository = @($upstreams.repositories | Where-Object name -CEQ framework)
if ($repository.Count -ne 1 -or $repository[0].canonicalUrl -cne 'https://github.com/alissonsol/yuruna.git') {
    throw 'Guest qualification requires the prepared canonical public framework.'
}
$repository = $repository[0]
$tree = [string](& git -C $repository.localPath rev-parse "$($repository.candidateCommit)^{tree}" 2>$null)
if ($LASTEXITCODE -or $tree.Trim() -cne $FrameworkTree) { throw 'Guest fixture does not match the frozen candidate tree.' }
$windowsGuest = $Scenario -like 'GM-WIN-*'
$localWork = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-native-guest-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($localWork) | Out-Null
$payload = @{
    scenario = $Scenario; revision = $repository.candidateCommit; repository = 'alissonsol/yuruna'
    mirror = $MirrorAddress; files = @{}
}
$sources = [ordered]@{}
$result = $null
try {
    if ($windowsGuest) {
        $checkout = Join-Path $localWork source
        $clone = Invoke-BoundedNativeCommand -FilePath git -ArgumentList @('clone', '--quiet', '--no-checkout', $repository.localPath, $checkout) -TimeoutSeconds 120
        if ($clone.ExitCode -or -not (Test-BoundedNativeResultComplete $clone)) { throw 'Cannot create the frozen seed source.' }
        foreach ($arguments in @(@('-C', $checkout, 'checkout', '--quiet', '--detach', $repository.candidateCommit),
                @('-C', $checkout, 'remote', 'set-url', 'origin', $repository.canonicalUrl))) {
            & git @arguments
            if ($LASTEXITCODE) { throw 'Cannot select the frozen seed source.' }
        }
        $seedRoot = $checkout
        if ($Scenario -ceq 'GM-WIN-GUEST-OLD-SEED') {
            $oldHead = [string](& git -C $OldRoot rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -or $oldHead.Trim() -cne '160bbb0855b3c304ad61ab45c02b7ef7c042721d') { throw 'Old seed requires the exact public release fixture.' }
            & git -C $OldRoot diff --quiet HEAD --
            if ($LASTEXITCODE) { throw 'The old seed fixture contains changed files.' }
            $seedRoot = $OldRoot
        }
        $module = Import-Module (Join-Path $seedRoot 'automation/Yuruna.GuestSeed.psm1') -Force -PassThru -DisableNameChecking
        $seed = & $module { param($source, $mirror)
            New-WindowsGuestBootstrap -RepoRoot $source -StatusServiceIp 127.0.0.1 `
                -StatusServicePort 1 -HostId qualification -CachingProxyIp $mirror `
                -FrameworkUrl https://github.com/alissonsol/yuruna.git -ProjectUrl '' -GhToken ''
        } $seedRoot $MirrorAddress
        $environment = [regex]::Match($seed.Files['yuruna-bootstrap.ps1'], '(?ms)^\s*YURUNA_HOST_ID=.*?^(?="@)')
        if (-not $environment.Success -or $environment.Value -match '__[A-Z_]+__') { throw 'The shipping seed did not render a complete host environment.' }
        $payload.seed = $environment.Value
        $updaterPath = Join-Path $root 'guest/windows.11/windows.11.update.ps1'
        $updater = [IO.File]::ReadAllText($updaterPath)
        $start = $updater.IndexOf('# --- REGION: Materialize the yuruna framework and project repos')
        $end = $updater.IndexOf('$yurunaProject = Join-Path', $start)
        if ($start -lt 0 -or $end -le $start) { throw 'Cannot locate the shipping Windows framework entry point.' }
        $payload.block = $updater.Substring($start, $end - $start)
        $sources['guest/windows.11/windows.11.update.ps1'] = (Get-FileHash $updaterPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $sources['seed/bootstrap'] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($seed.Files['yuruna-bootstrap.ps1']))).ToLowerInvariant()
        $program = @'
$ErrorActionPreference = 'Stop'
$p = __PAYLOAD__ | ConvertFrom-Json
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows seed qualification requires an actual Windows guest.' }
$work = Join-Path $env:TEMP ('yuruna-native-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$socket = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
$socket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
try {
    foreach ($name in @('E_FB_REPO','E_FB_REF','YURUNA_GITHUB_REPO','YURUNA_GITHUB_REF')) { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
    foreach ($line in ($p.seed -split '\r?\n')) {
        if ($line -match '^([A-Z_]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
    }
    $env:YURUNA_STATUS_SERVICE_PORT = [string]$socket.LocalEndPoint.Port
    $env:GIT_CONFIG_COUNT = '3'
    $env:GIT_CONFIG_KEY_0 = "url.http://$($p.mirror)/git/$($p.repository).git.insteadOf"
    $env:GIT_CONFIG_VALUE_0 = "https://github.com/$($p.repository).git"
    $env:GIT_CONFIG_KEY_1 = 'credential.helper'; $env:GIT_CONFIG_VALUE_1 = ''
    $env:GIT_CONFIG_KEY_2 = 'http.proxy'; $env:GIT_CONFIG_VALUE_2 = ''
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_CONFIG_GLOBAL = 'NUL'
    $env:HOME = $work; $env:USERPROFILE = $work
    foreach ($name in @('GH_TOKEN','GITHUB_TOKEN','GIT_ASKPASS','SSH_ASKPASS')) { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
    $yurunaRoot = Join-Path $work framework
    $frameworkVersion = Join-Path $yurunaRoot VERSION
    $frameworkUrl = $env:YURUNA_FRAMEWORK_URL
    $messages = @(& ([scriptblock]::Create($p.block)) *>&1)
    $legacy = $p.scenario -ceq 'GM-WIN-GUEST-OLD-SEED'
    if ($legacy) {
        $sha = ([string](& git -C $yurunaRoot rev-parse HEAD)).Trim()
        if ($LASTEXITCODE) { throw 'Old seeded clone did not produce a Git checkout.' }
        $source = 'legacy-clone'
    } else {
        $sha = [IO.File]::ReadAllText((Join-Path $yurunaRoot '.yuruna-revision')).Trim()
        if (($messages -join "`n") -notmatch 'source=lan-mirror') { throw 'The new seed did not use the mirror tier.' }
        foreach ($name in @('.git','docs','dev-only')) {
            if (Test-Path -LiteralPath (Join-Path $yurunaRoot $name)) { throw "Pinned materialization retained excluded path: $name" }
        }
        $source = 'lan-mirror'
    }
    if ($sha -cne $p.revision) { throw 'Guest installed a different commit from the frozen candidate.' }
    @{ passed=$true; guestPlatform='windows'; commit=$sha; source=$source; hostTransport='reserved-non-listening';
       seedHasPin=[bool]$env:YURUNA_GITHUB_REF; versionHash=(Get-FileHash $frameworkVersion -Algorithm SHA256).Hash.ToLowerInvariant() } |
        ConvertTo-Json -Compress
} finally { $socket.Dispose(); Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
'@
    } else {
        foreach ($relative in @('automation/fetch-and-execute.sh', 'automation/yuruna-retry.sh', 'automation/yuruna-fetch-context.sh')) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $root $relative))
            $payload.files[$relative] = [Convert]::ToBase64String($bytes)
            $sources[$relative] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
        $payload.payloadHash = $sources['automation/yuruna-fetch-context.sh']
        $payload.libraryHash = $sources['automation/yuruna-retry.sh']
        $program = @'
import base64, hashlib, json, os, pathlib, shutil, subprocess, tempfile, urllib.request
p = json.loads(__PAYLOAD__)
work = pathlib.Path(tempfile.mkdtemp(prefix="yuruna-native-guest-"))
previous_log = work / "previous-fetch.log"
log = pathlib.Path("/tmp/yuruna-last-fetch-and-execute.log")
try:
    environment = os.environ.copy()
    host = pathlib.Path("/etc/yuruna/host.env")
    if not host.is_file():
        raise RuntimeError("Unix qualification requires the actual provisioned host.env")
    for line in host.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            environment[key] = value.strip().strip('"')
    if environment.get("YURUNA_CACHING_PROXY_SERVICE_IP") != p["mirror"]:
        raise RuntimeError("Guest seed names a different mirror")
    host_url = "http://" + environment["YURUNA_STATUS_SERVICE_IP"] + ":" + environment["YURUNA_STATUS_SERVICE_PORT"] + "/livecheck"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(host_url, timeout=2) as response:
            if response.status == 200:
                raise ValueError("The seeded host status service is available; this is not a fallback drill")
    except ValueError:
        raise
    except Exception:
        pass
    for name, encoded in p["files"].items():
        path = work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(base64.b64decode(encoded, validate=True))
    environment.update(E_FB_REPO=p["repository"], E_FB_REF=p["revision"], E_SHA=p["payloadHash"],
                       E_RETRY_SHA=p["libraryHash"], EXEC_REQUIRE_SHA256="1", EXEC_PROFILE="0", EXEC_RECORDER="0", TERM="dumb")
    for name in ("EXEC_BASE_URL", "EXEC_ALLOW_UNVERIFIED", "GH_TOKEN", "GITHUB_TOKEN", "GIT_ASKPASS", "SSH_ASKPASS"):
        environment.pop(name, None)
    if p["scenario"] == "GM-GUEST-RAW-FALLBACK":
        if log.exists():
            log.rename(previous_log)
        completed = subprocess.run(["bash", str(work / "automation/fetch-and-execute.sh"), "automation/yuruna-fetch-context.sh", "--gui-capability"],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        evidence = log.read_text() if log.exists() else ""
        if completed.returncode or "# source: mirror" not in evidence or p["payloadHash"] not in evidence or b"YFE_GUI_1" not in completed.stdout:
            raise RuntimeError("The shipping raw fetcher did not execute the verified mirror payload: " + evidence[-3000:])
        result = dict(source="mirror", commit=p["revision"], payloadSha256=p["payloadHash"])
    else:
        home = work / "home"
        home.mkdir()
        completed = subprocess.run(["bash", "-c", '. "$1"; yuruna_materialize_repositories "$2" "$(id -un)" "$3" ""',
                                    "native-guest", str(work / "automation/yuruna-retry.sh"), str(home),
                                    "https://github.com/" + p["repository"] + ".git"],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=360)
        evidence = completed.stdout.decode("utf-8", "replace")
        target = home / "yuruna"
        if completed.returncode or "source=lan-mirror" not in evidence:
            raise RuntimeError("The shipping tree materializer did not use the mirror: " + evidence[-3000:])
        sha = (target / ".yuruna-revision").read_text().strip()
        if sha != p["revision"] or any((target / name).exists() for name in (".git", "docs", "dev-only")):
            raise RuntimeError("Materialized tree has the wrong commit or archive exclusions")
        result = dict(source="lan-mirror", commit=sha, versionHash=hashlib.sha256((target / "VERSION").read_bytes()).hexdigest())
    result.update(passed=True, guestPlatform=os.uname().sysname, hostTransport="measured-unavailable")
    print(json.dumps(result))
finally:
    if previous_log.exists():
        log.unlink(missing_ok=True)
        previous_log.rename(log)
    shutil.rmtree(work, ignore_errors=True)
'@
    }
    $json = ConvertTo-Json $payload -Depth 8 -Compress
    # JSON is data passed through a language literal, never interpolated as code.
    if ($windowsGuest) {
        $program = $program.Replace('__PAYLOAD__', ("'" + $json.Replace("'", "''") + "'"))
        $loader = '& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd()))))'
        $remoteCommand = 'powershell.exe -NoProfile -NonInteractive -EncodedCommand ' +
            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader))
        $inputText = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($program))
    } else {
        $encodedJson = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $program = $program.Replace('__PAYLOAD__', "base64.b64decode('$encodedJson').decode('utf-8')")
        $remoteCommand = "python3 -c 'import sys; exec(compile(sys.stdin.read(), `"native-guest`", `"exec`"))'"
        $inputText = $program
    }
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command ssh -CommandType Application).Source)
    foreach ($argument in @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10',
            '-i', [IO.Path]::GetFullPath($SshKeyPath), $GuestHost, $remoteCommand)) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($inputText); $process.StandardInput.Close()
        if (-not $process.WaitForExit(480000)) { $process.Kill($true); throw 'Native guest materialization exceeded its deadline.' }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) { throw 'Native guest transport left its output incomplete.' }
        if ($process.ExitCode) { throw "Native guest materialization failed: $($stderr.Result)" }
        $result = $stdout.Result | ConvertFrom-Json -AsHashtable
        if (-not $result.passed -or $result.commit -cne $repository.candidateCommit) { throw 'Guest evidence did not confirm the frozen candidate.' }
        $result.schema = 'yuruna.git-mirror.native-guest/v1'
        $result.scenario = $Scenario; $result.sourceHashes = $sources; $result.expectedTree = $FrameworkTree
        [IO.File]::WriteAllText($output, ($result | ConvertTo-Json -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
    } finally { if (-not $process.HasExited) { $process.Kill($true) }; $process.Dispose() }
} finally { Remove-Item -LiteralPath $localWork -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output $output
