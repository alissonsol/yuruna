<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42b8c9d0-e1f2-4a34-b5c6-7d8e9f0a1b2c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Test.OcrEngine
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
    Pluggable OCR engine registry. Enables running multiple OCR providers on the
    same image and combining their results.

.DESCRIPTION
    Provides a provider pattern for OCR engines. Each provider is registered with
    a name, an invocation scriptblock (image path -> text), and an availability
    check. Built-in providers: tesseract, winrt (Windows), macos-vision (macOS).

    Configuration:
      $env:YURUNA_OCR_ENGINES  — comma-separated list of provider names to enable.
                                  Default: "tesseract"
                                  Example: "tesseract,winrt"

    The combine mode for multi-engine results is controlled separately by the
    caller (see Wait-ForText in Invoke-Sequence.psm1).
#>

# ── Provider registry ───────────────────────────────────────────────────────
#
# Backed by Test.Registry's New-YurunaRegistry primitive so the shape
# matches Test.SequenceAction and Test.HostIO. An autonomous remediator
# can introspect all three registries through the same closure-bundle
# API (Register / Get / Has / GetMatrix / Clear) instead of three
# different ad-hoc layouts. The $global:YurunaOcrProviders anchor name
# is preserved so any cross-module reader keeps working.

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global

$script:OcrProviderRegistry = New-YurunaRegistry -Name 'OcrProvider' -AnchorVar 'YurunaOcrProviders' -Comparer 'OrdinalIgnoreCase'

function Register-OcrProvider {
    <#
    .SYNOPSIS
        Registers an OCR provider with the engine registry.
    .PARAMETER Name
        Unique name for this provider (e.g. 'tesseract', 'winrt', 'macos-vision').
    .PARAMETER Invoke
        Scriptblock that takes a single string parameter (image path) and returns
        the recognized text as a string.
    .PARAMETER IsAvailable
        Scriptblock that returns $true if this provider can run on the current platform.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Invoke,
        [Parameter(Mandatory)] [scriptblock]$IsAvailable
    )
    $entry = @{
        Name        = $Name
        Invoke      = $Invoke
        IsAvailable = $IsAvailable
    }
    & $script:OcrProviderRegistry.Register $Name $entry
}

function Get-OcrProviderName {
    <#
    .SYNOPSIS
        Returns the names of all registered OCR providers.
    #>
    return @($script:OcrProviderRegistry.Store[0].Keys)
}

function Test-OcrProviderAvailable {
    <#
    .SYNOPSIS
        Tests whether a named OCR provider is available on the current platform.
    #>
    param([Parameter(Mandatory)] [string]$Name)
    $provider = & $script:OcrProviderRegistry.Get $Name
    if (-not $provider) { return $false }
    return [bool](& $provider.IsAvailable)
}

function Invoke-OcrProvider {
    <#
    .SYNOPSIS
        Runs a single named OCR provider on an image and returns the recognized text.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ImagePath
    )
    $provider = & $script:OcrProviderRegistry.Get $Name
    if (-not $provider) { throw "OCR provider '$Name' is not registered." }
    return (& $provider.Invoke $ImagePath)
}

# Process-lifetime memo of the resolved enabled-provider list. Key is the raw
# $env:YURUNA_OCR_ENGINES value (the platform branch is invariant within a
# process), so an operator changing the env var still re-resolves. Without it the
# availability probes (Test-OcrProviderAvailable -> & $provider.IsAvailable) run
# on every OCR poll; mirrors the Find-Tesseract path cache in Test.Tesseract.psm1.
$script:EnabledOcrProviderCache = $null
$script:EnabledOcrProviderCacheKey = $null

function Clear-EnabledOcrProviderCache {
    <#
    .SYNOPSIS
        Drops the memoized enabled-provider list (test seam / env-change hook).
    #>
    $script:EnabledOcrProviderCache = $null
    $script:EnabledOcrProviderCacheKey = $null
}

function Get-EnabledOcrProvider {
    <#
    .SYNOPSIS
        Returns the list of OCR provider names that are enabled via configuration
        AND available on the current platform.
    .DESCRIPTION
        Reads $env:YURUNA_OCR_ENGINES (comma-separated). Falls back to a
        platform-dependent default when the env var is unset.
        Filters out providers that are not available on the current platform.

        Default ORDER matters: callers compose this list with combine mode
        'Or' (see Get-OcrCombineMode in Invoke-Sequence.psm1), which
        short-circuits on the first engine that finds the search pattern.
        So the first engine listed here is the primary; later engines are
        fallbacks invoked only when the primary's text didn't match.
    #>
    $envVal = $env:YURUNA_OCR_ENGINES
    $cacheKey = if ($null -eq $envVal) { '<unset>' } else { [string]$envVal }
    if (($script:EnabledOcrProviderCacheKey -eq $cacheKey) -and ($null -ne $script:EnabledOcrProviderCache)) {
        return $script:EnabledOcrProviderCache
    }
    $requested = if ($envVal) {
        $envVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } elseif ($IsMacOS) {
        # host.macos.utm — Apple Vision is the native engine, fastest path
        # to a match. After the x-axis crop fix in Invoke-MacVisionOcr the
        # silent-empty case has gone away for the framebuffer captures the
        # runner actually feeds it. Tesseract sits behind as a fallback
        # for the few cases Vision still returns nothing (sparse glyphs in
        # unusual fonts, very low contrast bands). With combine mode 'Or'
        # tesseract only runs when Vision did NOT match the search
        # pattern, so the common case is one OCR call per poll. winrt is
        # omitted entirely — it is Windows-only and would be filtered out
        # at runtime anyway; listing it here only adds confusing log
        # lines about a provider that can't run.
        @('macos-vision', 'tesseract')
    } elseif ($IsWindows) {
        # host.windows.hyper-v — WinRT (Windows.Media.Ocr) is native and
        # available on every Windows 10+ machine. Tesseract is the cross-
        # platform fallback. macos-vision is omitted (Apple framework,
        # not available off macOS).
        @('winrt', 'tesseract')
    } elseif ($IsLinux) {
        # host.ubuntu.kvm — tesseract is the only OCR engine we ship for
        # this host. macos-vision (Apple framework) and winrt (Windows
        # framework) cannot run here.
        @('tesseract')
    } else {
        # Unknown platform — fall through to all three; Test-OcrProvider-
        # Available will filter at runtime.
        @('tesseract', 'winrt', 'macos-vision')
    }

    $available = @()
    foreach ($name in $requested) {
        if (Test-OcrProviderAvailable $name) {
            $available += $name
        } else {
            Write-Verbose "OCR provider '$name' not available on this platform — skipping."
            # Structured drop signal so a remediator notices the OCR
            # surface is degraded (e.g. tesseract uninstalled by an OS
            # update) without having to diff -Verbose logs.
            # Guard: Test.OcrEngine does not import Test.Log, so in a degraded
            # context where the logger is absent this event must not throw.
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'ocr_provider_unavailable'
                    provider     = [string]$name
                    requested    = @($requested)
                    failureClass = 'instrumentation_failure'
                    severity     = 'soft'
                }
            }
        }
    }
    $script:EnabledOcrProviderCacheKey = $cacheKey
    $script:EnabledOcrProviderCache = $available
    return $available
}

function Invoke-AllEnabledOcr {
    <#
    .SYNOPSIS
        Runs all enabled OCR providers on the given image.
    .DESCRIPTION
        Returns an ordered hashtable: provider-name -> recognized text.
        Providers that fail are logged and their entry is set to empty string.
    .PARAMETER ImagePath
        Path to the image file to OCR.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary. Keys are provider names,
        values are the recognized text (string).
    #>
    param([Parameter(Mandatory)] [string]$ImagePath)

    $results = [ordered]@{}
    foreach ($name in (Get-EnabledOcrProvider)) {
        try {
            $results[$name] = Invoke-OcrProvider -Name $name -ImagePath $ImagePath
        } catch {
            $ocrErr = $_
            Write-Warning "OCR provider '$name' failed: $ocrErr"
            $results[$name] = ''
            # Structured failure signal so a remediator routes on
            # `event=ocr_provider_failed` (vs the silent empty-string
            # results entry that downstream waitForText consumers see).
            # Guard: Test.OcrEngine does not import Test.Log, so in a degraded
            # context where the logger is absent this event must not throw.
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'ocr_provider_failed'
                    provider     = [string]$name
                    imagePath    = [string]$ImagePath
                    error        = $ocrErr.Exception.Message
                    failureClass = 'instrumentation_failure'
                    severity     = 'soft'
                }
            }
        }
    }
    return $results
}

# ── Built-in provider: Tesseract ────────────────────────────────────────────

# -Global is mandatory: a bare -Force re-import of an already-global
# Test.Tesseract yanks it out of the global session into this module's
# private scope (legacy module-eviction regression class). Because this
# line re-runs every time Test.OcrEngine is re-imported -- and the
# Invoke-Sequence -> Test.OcrMatch -> Test.OcrEngine chain re-imports it
# on each Initialize-SequenceEngineRegistry -- the eviction would leave
# Tesseract's exports (Assert-TesseractInstalled, ...) invisible to the
# entry-point's global scope even though Test.OcrEngine's own exports
# stay resolvable. Keep -Global so Tesseract stays globally visible.
Import-Module (Join-Path $PSScriptRoot "Test.Tesseract.psm1") -Force -Global -Verbose:$false

Register-OcrProvider -Name 'tesseract' `
    -Invoke {
        param([string]$ImagePath)
        Invoke-TesseractOcr -ImagePath $ImagePath
    } `
    -IsAvailable {
        [bool](Find-Tesseract)
    }

# ── Built-in provider: WinRT (Windows only, via powershell.exe 5.1) ────────
# Windows.Media.Ocr is available on all Windows 10+ machines but requires
# PowerShell 5.1 (powershell.exe) because .NET 6+ removed WinRT projection.

# The OCR helper script runs inside Windows PowerShell 5.1 which still has
# WinRT interop. Stored once at module scope and written to a content-hashed
# temp path on first use (see Get-WinRtOcrScriptPath); reused across every
# Invoke-WinRtOcr call so we save the per-call Set-Content + random-name
# overhead. The persistent path also means a new release of this module
# (different script text → different hash → different path) coexists with
# any older binary still cached from a prior cycle.
$script:WinRtOcrScript = @'
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

$imagePath = $args[0]
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imagePath)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])

[Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
$rawBitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$bitmap = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert(
    $rawBitmap,
    [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
    [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)

$ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $ocrEngine) { throw 'WinRT OcrEngine not available' }
$ocrResult = Await ($ocrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

foreach ($line in $ocrResult.Lines) {
    $line.Text
}
'@

# Lazy-write cache for the WinRT helper script. The script body is in
# $script:WinRtOcrScript; we hash it (first 16 hex chars of SHA-256) so a
# source edit lands at a different path -- if the module is re-imported
# mid-cycle after an edit, the next call writes a fresh file instead of
# silently re-using stale content.
$script:WinRtOcrScriptPath = $null

function Get-WinRtOcrScriptPath {
    if ($script:WinRtOcrScriptPath -and (Test-Path $script:WinRtOcrScriptPath)) {
        return $script:WinRtOcrScriptPath
    }
    $hash = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes($script:WinRtOcrScript)
        )
    ).Replace('-','').Substring(0, 16).ToLowerInvariant()
    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-winrt-ocr-$hash.ps1"
    if (-not (Test-Path $scriptFile)) {
        $script:WinRtOcrScript | Set-Content -Path $scriptFile -Encoding UTF8
    }
    $script:WinRtOcrScriptPath = $scriptFile
    return $scriptFile
}

# Persistent WinRT worker (default on; YURUNA_OCR_WORKER=0 disables it).
# Timing rationale, wire protocol, and lifecycle: https://yuruna.link/ocr
$script:WinRtOcrWorkerScript = @'
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

$ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $ocrEngine) {
    [Console]::Out.WriteLine('__YURUNA_EOR_ERR__ WinRT OcrEngine not available')
    [Console]::Out.Flush()
    exit 1
}

[Console]::Out.WriteLine('__YURUNA_READY__')
[Console]::Out.Flush()

while ($null -ne ($imagePath = [Console]::In.ReadLine())) {
    if ($imagePath -eq '') { continue }
    try {
        $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imagePath)) ([Windows.Storage.StorageFile])
        $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $rawBitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $bitmap = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert(
            $rawBitmap,
            [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
            [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)
        $ocrResult = Await ($ocrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        foreach ($line in $ocrResult.Lines) {
            [Console]::Out.WriteLine($line.Text)
        }
        [Console]::Out.WriteLine('__YURUNA_EOR_OK__')
    } catch {
        $msg = $_.Exception.Message -replace "[\r\n]+", ' '
        [Console]::Out.WriteLine("__YURUNA_EOR_ERR__ $msg")
    }
    [Console]::Out.Flush()
}
'@

$script:WinRtOcrWorkerScriptPath = $null
$script:WinRtOcrWorker = $null

# Win32 Job Object bound to this pwsh process. Anything we
# AssignProcessToJobObject into this job is killed by the OS when the
# last handle to the job closes -- and the only handle exists in our
# process, so process exit (orderly, crash, watchdog kill, Ctrl+C)
# tears the worker down without relying on managed shutdown hooks.
# OnRemove handles the graceful path; the job covers everything else.
if ($IsWindows -and -not ('YurunaWinRtOcrJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class YurunaWinRtOcrJob
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr hJob, int infoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    private static readonly object _gate = new object();
    private static IntPtr _job = IntPtr.Zero;

    private static IntPtr EnsureJob()
    {
        if (_job != IntPtr.Zero) return _job;
        lock (_gate)
        {
            if (_job != IntPtr.Zero) return _job;
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");

            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(info);
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buf, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buf, (uint)size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject failed");
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            _job = job;
            return _job;
        }
    }

    public static void Assign(IntPtr processHandle)
    {
        IntPtr job = EnsureJob();
        if (!AssignProcessToJobObject(job, processHandle))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed");
    }
}
'@
}

function Get-WinRtOcrWorkerScriptPath {
    if ($script:WinRtOcrWorkerScriptPath -and (Test-Path $script:WinRtOcrWorkerScriptPath)) {
        return $script:WinRtOcrWorkerScriptPath
    }
    $hash = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes($script:WinRtOcrWorkerScript)
        )
    ).Replace('-','').Substring(0, 16).ToLowerInvariant()
    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-winrt-ocr-worker-$hash.ps1"
    if (-not (Test-Path $scriptFile)) {
        $script:WinRtOcrWorkerScript | Set-Content -Path $scriptFile -Encoding UTF8
    }
    $script:WinRtOcrWorkerScriptPath = $scriptFile
    return $scriptFile
}

function Start-WinRtOcrWorker {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Diagnostics.Process])]
    param()
    if ($script:WinRtOcrWorker -and -not $script:WinRtOcrWorker.HasExited) {
        return $script:WinRtOcrWorker
    }
    if (-not $PSCmdlet.ShouldProcess('powershell.exe', 'Spawn persistent WinRT OCR worker')) { return $null }
    $script:WinRtOcrWorker = $null
    $scriptFile = Get-WinRtOcrWorkerScriptPath
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName  = 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $scriptFile + '"'
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.StandardInputEncoding  = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    $p = [System.Diagnostics.Process]::Start($psi)

    # Bind to the parent-owned Job Object before reading any output.
    # If this fails we can't guarantee the worker dies with us, so we
    # kill what we just spawned and throw -- Invoke-WinRtOcr's outer
    # catch falls back to one-shot for the affected call. Better a
    # slower call than an orphaned powershell.exe surviving Ctrl+C.
    try {
        [YurunaWinRtOcrJob]::Assign($p.Handle)
    } catch {
        try { $p.Kill() } catch { $null = $_ }
        throw "WinRT OCR worker job-bind failed: $($_.Exception.Message)"
    }

    # Block until the worker prints __YURUNA_READY__. Cold-start cost
    # (~150-300 ms) is paid here, on the first OCR call, instead of
    # blocking the OCR call itself with no caller visibility. Anything
    # else printed before READY (provider noise, Add-Type warnings) is
    # logged Verbose so it surfaces with -Verbose without polluting
    # normal output.
    while ($true) {
        $line = $p.StandardOutput.ReadLine()
        if ($null -eq $line) {
            $stderr = ''
            try { $stderr = $p.StandardError.ReadToEnd() } catch { $null = $_ }
            $exitCode = if ($p.HasExited) { $p.ExitCode } else { -1 }
            throw "WinRT OCR worker exited before signaling ready (exit $exitCode). stderr: $stderr"
        }
        if ($line -eq '__YURUNA_READY__') {
            $script:WinRtOcrWorker = $p
            return $p
        }
        if ($line.StartsWith('__YURUNA_EOR_ERR__')) {
            try { $p.Kill() } catch { $null = $_ }
            throw "WinRT OCR worker startup failed: $line"
        }
        Write-Verbose "WinRT OCR worker pre-ready: $line"
    }
}

function Stop-WinRtOcrWorker {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $w = $script:WinRtOcrWorker
    if (-not $w) { return }
    if (-not $PSCmdlet.ShouldProcess("PID $($w.Id)", 'Stop WinRT OCR worker')) { return }
    $script:WinRtOcrWorker = $null
    try {
        if (-not $w.HasExited) {
            try { $w.StandardInput.Close() } catch { $null = $_ }
            if (-not $w.WaitForExit(2000)) {
                try { $w.Kill() } catch { $null = $_ }
            }
        }
    } catch {
        Write-Verbose "Stop-WinRtOcrWorker: $($_.Exception.Message)"
    }
}

function Invoke-WinRtOcrViaWorker {
    [CmdletBinding()]
    [OutputType([System.String])]
    param([Parameter(Mandatory)][string]$ImagePath)

    $w = Start-WinRtOcrWorker -Confirm:$false
    try {
        $w.StandardInput.WriteLine($ImagePath)
        $w.StandardInput.Flush()
    } catch {
        Stop-WinRtOcrWorker -Confirm:$false
        throw "WinRT OCR worker stdin write failed: $($_.Exception.Message)"
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = $w.StandardOutput.ReadLine()
        if ($null -eq $line) {
            Stop-WinRtOcrWorker -Confirm:$false
            throw "WinRT OCR worker stdout closed mid-response"
        }
        if ($line -eq '__YURUNA_EOR_OK__') {
            return ($lines -join "`n")
        }
        if ($line.StartsWith('__YURUNA_EOR_ERR__')) {
            throw ('WinRT OCR worker error: ' + $line.Substring('__YURUNA_EOR_ERR__'.Length).TrimStart())
        }
        $lines.Add($line)
    }
}

# Module-unload hook: close worker stdin so the worker exits its read
# loop cleanly; Kill() after 2 s if it doesn't. Fires on Remove-Module
# and on the next -Force import (which evicts the previous instance).
$ExecutionContext.SessionState.Module.OnRemove = {
    $w = $script:WinRtOcrWorker
    if ($w -and -not $w.HasExited) {
        try {
            $w.StandardInput.Close()
            $null = $w.WaitForExit(2000)
            if (-not $w.HasExited) { $w.Kill() }
        } catch { $null = $_ }
    }
}

function Invoke-WinRtOcr {
    <#
    .SYNOPSIS
        Runs Windows.Media.Ocr on an image by shelling out to powershell.exe (5.1).
    .DESCRIPTION
        Default: dispatches through a persistent powershell.exe worker kept
        alive for the lifetime of this runspace (see Invoke-WinRtOcr-
        ViaWorker), which collapses the per-call cold-spawn cost from
        ~150-300 ms to ~5-15 ms after the first call. Set
        YURUNA_OCR_WORKER=0 in the environment to disable the worker and
        use a fresh powershell.exe spawn per call (reuses a persistent
        script file via Get-WinRtOcrScriptPath). Worker failures fall
        back to the one-shot path for the
        affected call so a broken worker can never harden into a
        permanent OCR outage.
    .PARAMETER ImagePath
        Path to a PNG image file.
    .OUTPUTS
        System.String. The recognized text.
    #>
    param([Parameter(Mandatory)] [string]$ImagePath)

    $absPath = (Resolve-Path $ImagePath).Path

    # Worker is on by default. Operator opt-out: YURUNA_OCR_WORKER=0.
    # Any other value (including unset / empty / '1' / 'true') keeps
    # the worker engaged.
    if ($env:YURUNA_OCR_WORKER -ne '0') {
        try {
            return (Invoke-WinRtOcrViaWorker -ImagePath $absPath)
        } catch {
            Write-Verbose "WinRT OCR worker failed ($($_.Exception.Message)); falling back to one-shot spawn for this call."
            # fall through to the one-shot path
        }
    }

    $scriptFile = Get-WinRtOcrScriptPath
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptFile $absPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errLines = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
        throw "WinRT OCR failed (exit $LASTEXITCODE): $errLines"
    }
    $text = ($output | Where-Object { $_ -is [string] }) -join "`n"
    return $text
}

Register-OcrProvider -Name 'winrt' `
    -Invoke {
        param([string]$ImagePath)
        Invoke-WinRtOcr -ImagePath $ImagePath
    } `
    -IsAvailable {
        $IsWindows -and [bool](Get-Command powershell.exe -ErrorAction SilentlyContinue)
    }

# macOS Vision provider (VNRecognizeTextRequest via Swift; macOS 10.15+).
# Densest-row crop, PNG round-trip, and usesLanguageCorrection=false are
# all load-bearing — rationale at https://yuruna.link/ocr
$script:VisionOcrSwift = @'
import Vision
import AppKit
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count > 1 else { exit(1) }
let imagePath = CommandLine.arguments[1]

guard let image = NSImage(contentsOfFile: imagePath),
      let tiff  = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let original = bitmap.cgImage else {
    fputs("Failed to load image: \(imagePath)\n", stderr)
    exit(1)
}

// ── 1. Per-row lit-pixel count (luma > 96) ────────────────────────────────
let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
let bpp = bitmap.bitsPerPixel, bpr = bitmap.bytesPerRow
guard let data = bitmap.bitmapData else {
    fputs("bitmapData nil — cannot find content cluster\n", stderr); exit(1)
}
let pxBytes = bpp / 8
var litPerRow = [Int](repeating: 0, count: h)
for y in 0..<h {
    let row = data + y * bpr
    var c = 0
    for x in 0..<w {
        let p = row + x * pxBytes
        if max(p[0], max(p[1], p[2])) > 96 { c += 1 }
    }
    litPerRow[y] = c
}

// Skip a leading "all-white" bar (UTM toolbar / window chrome when the
// capture includes it). Threshold 90% of width AT high luma rejects normal
// text rows and accepts only solid lit stripes.
var topSkip = 0
for y in 0..<h {
    if litPerRow[y] > Int(Double(w) * 0.9) { topSkip = y + 1 } else { break }
}

// ── 2. Cluster rows with > 8 lit pixels, gap up to ~80 dark rows ───────────
// 80 px ≈ 2 line-heights at this resolution; allows blank lines between
// content lines (login prompt below "Ubuntu 24.04..." banner) to stay in
// the same cluster, but separates content from later artifacts (cursor,
// status bar) hundreds of rows away.
let minRowLit = 8
let maxGap    = 80
var clusters: [(start: Int, end: Int, total: Int)] = []
var cs = -1, ce = -1, ct = 0, gap = 0
for y in topSkip..<h {
    if litPerRow[y] > minRowLit {
        if cs < 0 { cs = y }
        ce = y; ct += litPerRow[y]; gap = 0
    } else if cs >= 0 {
        gap += 1
        if gap > maxGap {
            clusters.append((cs, ce, ct))
            cs = -1; ce = -1; ct = 0; gap = 0
        }
    }
}
if cs >= 0 { clusters.append((cs, ce, ct)) }

guard let best = clusters.max(by: { $0.total < $1.total }) else {
    // No content — exit cleanly with no output.
    exit(0)
}

// ── 3. Crop to the densest cluster, padded ───────────────────────────────
// CGImage.cropping uses image-data (top-left) origin, NOT the bottom-left
// CGContext origin used elsewhere in CG. Mixing the two conventions
// produces bottom-of-image crops where the caller meant top-of-image,
// and Vision then sees a black tile and returns 0 obs.
//
// Crop BOTH x and y to the text bounding box. The x-axis crop was added
// after the QEMU+VNC switch: VNC framebuffers of a Linux console at 1920
// wide put the entire prompt in the leftmost ~700 px, so the cluster's
// 1920 × ~80 strip is mostly black on the right two thirds. Empirically,
// Vision's text detector silently returns 0 observations when the
// text-to-image-area ratio drops below some threshold around the
// 1200-wide mark (probed on macOS 26 / Vision 4.x with VNC captures of
// `<host> login:` on a 1920 x 1080 framebuffer). The y-only crop fixed
// the AVF/screencapture cases because those filled the full width with
// UI chrome; the QEMU/VNC case needs both axes trimmed.
let pad = 16
let cropY0 = max(0, best.start - pad)
let cropH  = min(h - cropY0, (best.end - cropY0) + pad + 1)
// X-bbox: leftmost and rightmost lit pixel inside the cluster's row range.
// Same minLumThreshold (96) as the per-row count so the bbox lines up with
// the cluster we already chose. If a row in [best.start, best.end] has no
// lit pixels (a blank line between banner and prompt), we just skip it.
var minLitX = w, maxLitX = -1
for y in best.start...best.end {
    let row = data + y * bpr
    for x in 0..<w {
        let p = row + x * pxBytes
        if max(p[0], max(p[1], p[2])) > 96 {
            if x < minLitX { minLitX = x }
            if x > maxLitX { maxLitX = x }
        }
    }
}
let cropX0: Int
let cropW: Int
if maxLitX >= minLitX {
    cropX0 = max(0, minLitX - pad)
    cropW  = min(w - cropX0, (maxLitX - cropX0) + pad + 1)
} else {
    cropX0 = 0
    cropW  = w
}
let cropped = original.cropping(to: CGRect(x: cropX0, y: cropY0, width: cropW, height: cropH))!

// ── 4. PNG round-trip: strip DisplayP3 + 144 DPI metadata ────────────────
// macOS screencapture writes DisplayP3-tagged 144-DPI PNGs. Vision's text
// detector is reliable on sRGB/72-DPI inputs but returns 0 observations
// on the wide-gamut originals — empirically, on every UTM screen capture
// of the login prompt — so we route through CGImageDestination to drop
// both tags. Use a per-PID temp path so concurrent OCR runs don't clobber
// each other's intermediate file.
let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("yuruna-vision-\(getpid())-\(UUID().uuidString).png")
defer { try? FileManager.default.removeItem(at: tmpURL) }
let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cropped, nil)
CGImageDestinationFinalize(dest)
let reload = CGImageSourceCreateWithURL(tmpURL as CFURL, nil)!
let cleanCG = CGImageSourceCreateImageAtIndex(reload, 0, nil)!

// ── 5. OCR ────────────────────────────────────────────────────────────────
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
// usesLanguageCorrection = false: terminal text (hostnames, cloud-init
// timestamps, "ttyl"/"tty1", "@/0/1" punctuation) is not natural language.
// Language correction was actively rewriting valid OCR into nonsense and
// was the single most expensive accuracy hit on the engine.
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]

let handler = VNImageRequestHandler(cgImage: cleanCG)
try handler.perform([request])

guard let observations = request.results, !observations.isEmpty else { exit(0) }

// Sort top-to-bottom, group into rows, then left-to-right within each row.
struct TextFragment {
    let text: String
    let x: CGFloat   // left edge (0..1)
    let y: CGFloat   // top edge (1 - bottomY - height; smaller = higher on screen)
    let h: CGFloat
}
var fragments: [TextFragment] = []
for obs in observations {
    guard let cand = obs.topCandidates(1).first else { continue }
    let b = obs.boundingBox
    let topY = 1.0 - b.origin.y - b.size.height
    fragments.append(TextFragment(text: cand.string, x: b.origin.x, y: topY, h: b.size.height))
}
fragments.sort { $0.y < $1.y }

let heights = fragments.map { $0.h }.sorted()
let medianH = heights[heights.count / 2]
let tolerance = max(medianH * 0.5, 0.005)

var rows: [[TextFragment]] = [[fragments[0]]]
var curY = fragments[0].y
for i in 1..<fragments.count {
    let f = fragments[i]
    if abs(f.y - curY) <= tolerance {
        rows[rows.count - 1].append(f)
    } else {
        rows.append([f]); curY = f.y
    }
}
for row in rows {
    print(row.sorted { $0.x < $1.x }.map { $0.text }.joined(separator: " "))
}
'@

# Lazy-compile cache for the Vision OCR Swift source. `swift script.swift`
# re-runs the Swift frontend on every invocation -- empirically 1-2s per
# call on Apple Silicon, which dominates Wait-ForText latency on macOS
# UTM hosts when Vision is the primary engine (the macOS default).
# `swiftc -O` compiles once to a native binary; subsequent invocations
# are pure exec, ~50-150ms. We key the binary path by SHA-256 of the
# source so an in-place edit triggers a fresh compile, and so multiple
# parallel cycles don't fight over the same path.
#
# Returns $null when swiftc is unavailable or compilation fails;
# Invoke-MacVisionOcr falls back to the original `swift script.swift`
# code path so behavior is preserved (just slower) on those hosts.
$script:VisionOcrBinaryPath = $null

function Get-VisionOcrBinaryPath {
    [CmdletBinding()]
    [OutputType([System.String])]
    param()

    if ($script:VisionOcrBinaryPath -and (Test-Path $script:VisionOcrBinaryPath)) {
        return $script:VisionOcrBinaryPath
    }
    $script:VisionOcrBinaryPath = $null
    if (-not (Get-Command swiftc -ErrorAction SilentlyContinue)) { return $null }

    $hash = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes($script:VisionOcrSwift)
        )
    ).Replace('-','').Substring(0, 16).ToLowerInvariant()
    $binPath = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-vision-ocr-$hash.bin"
    if (Test-Path $binPath) {
        $script:VisionOcrBinaryPath = $binPath
        return $binPath
    }

    # Compile into a sibling tmp path then Move-Item over the canonical
    # name so a partial/aborted compile can't leave a half-written binary
    # that subsequent calls would execute. -O is the standard optimisation
    # level; the Vision OCR work itself is the bulk of the runtime so a
    # heavier -O level would not materially help.
    $swiftFile = [System.IO.Path]::GetTempFileName() + '.swift'
    $tmpBin    = "$binPath.tmp.$PID"
    try {
        $script:VisionOcrSwift | Set-Content -Path $swiftFile -Encoding UTF8
        & swiftc -O $swiftFile -o $tmpBin 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpBin)) {
            Write-Verbose "Vision OCR swiftc compile failed (exit $LASTEXITCODE); falling back to 'swift script.swift' invocation path."
            return $null
        }
        Move-Item -Path $tmpBin -Destination $binPath -Force
        $script:VisionOcrBinaryPath = $binPath
        return $binPath
    } catch {
        Write-Verbose "Vision OCR swiftc compile threw: $($_.Exception.Message); using script-path fallback."
        return $null
    } finally {
        if (Test-Path $swiftFile) { Remove-Item $swiftFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpBin)    { Remove-Item $tmpBin    -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-MacVisionOcr {
    <#
    .SYNOPSIS
        Runs Apple Vision framework text recognition on an image via Swift.
    .PARAMETER ImagePath
        Path to a PNG image file.
    .OUTPUTS
        System.String. The recognized text.
    #>
    param([Parameter(Mandatory)] [string]$ImagePath)

    # Fast path: invoke the pre-compiled native binary if Get-VisionOcr-
    # BinaryPath has one (or can build one on first call). Saves the
    # ~1-2s `swift script.swift` recompile cost on every OCR poll.
    $binPath = Get-VisionOcrBinaryPath
    if ($binPath) {
        $output = & $binPath $ImagePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errMsg = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
            throw "Vision OCR failed: $errMsg"
        }
        return ($output | Where-Object { $_ -is [string] }) -join "`n"
    }

    # Fallback: swiftc unavailable or compile failed -- invoke the script
    # directly via `swift`.
    $swiftFile = [System.IO.Path]::GetTempFileName() + '.swift'
    try {
        $script:VisionOcrSwift | Set-Content -Path $swiftFile -Encoding UTF8
        $output = & swift $swiftFile $ImagePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errMsg = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
            throw "Vision OCR failed: $errMsg"
        }
        return ($output | Where-Object { $_ -is [string] }) -join "`n"
    } finally {
        if (Test-Path $swiftFile) { Remove-Item $swiftFile -Force }
    }
}

Register-OcrProvider -Name 'macos-vision' `
    -Invoke {
        param([string]$ImagePath)
        Invoke-MacVisionOcr -ImagePath $ImagePath
    } `
    -IsAvailable {
        $IsMacOS -and [bool](Get-Command swift -ErrorAction SilentlyContinue)
    }

# ── Exports ─────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Register-OcrProvider'
    'Get-OcrProviderName'
    'Test-OcrProviderAvailable'
    'Invoke-OcrProvider'
    'Get-EnabledOcrProvider'
    'Clear-EnabledOcrProviderCache'
    'Invoke-AllEnabledOcr'
    'Invoke-WinRtOcr'
    'Invoke-MacVisionOcr'
)
