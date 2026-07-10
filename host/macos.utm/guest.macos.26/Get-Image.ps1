<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42e1f2a3-b4c5-4d67-e890-1f2a3b4c5d68
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Downloads the latest macOS 26 IPSW restore image for Apple Virtualization.

.DESCRIPTION
    Apple does not publish a stable directory listing for IPSWs. The
    canonical discovery path is VZMacOSRestoreImage.fetchLatestSupported
    in the Virtualization framework, which returns the current latest
    IPSW URL + build number for the host Mac's hardware bucket. We invoke
    a small Swift program to call it, parse the resulting URL, and then
    download via Save-CachedHttpUri the same way the Linux/Windows guest
    images do.

    The squid cache rarely helps here (IPSWs are 15-20GB and per-build);
    Save-CachedHttpUri falls back to a direct Invoke-WebRequest when no
    cache is reachable.

    macOS 26 is gated at restore time: the Swift helper accepts the URL
    only when the published build advertises operatingSystemVersion >= 26.
    Apple bumps the URL when a new build ships; the skip-if-same-source
    guard avoids re-downloading the same build on a repeat run.
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsMacOS) {
    Write-Error "Get-Image.ps1 for guest.macos.26 only runs on macOS (Apple Virtualization required)."
    exit 1
}

# --- REGION: Configuration
$downloadDir   = "$HOME/yuruna/image/macos.env"
$baseImageName = "host.macos.utm.guest.macos.26"
$baseImageFile = Join-Path $downloadDir "$baseImageName.ipsw"
$baseImageOrigin = Join-Path $downloadDir "$baseImageName.txt"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# --- REGION: Resolve the latest IPSW URL via the Virtualization framework
#
# VZMacOSRestoreImage.fetchLatestSupported returns the IPSW URL + build
# number for the current host's hardware bucket. We refuse anything
# below macOS 26 -- on an M3-or-older host Apple may still publish
# macOS 15 here, and silently falling back would be confusing.
#
# Output contract (one line, tab-separated): URL<TAB>BUILD<TAB>VERSION
# Any failure prints a line starting with "ERROR_KIND=<kind>" to stderr
# (xcode-missing / version-below-floor / vz-catalog-fetch / vz-other),
# so PowerShell can emit a targeted hint instead of a blanket
# "install Xcode CLT" advice.

# Up-front swift sanity check. Reaches this point with a clear, actionable
# message before we burn time on a here-string + temp-file dance for what
# is really just a "command not found".
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    Write-Error "swift not found on PATH. The macOS 26 IPSW catalog probe needs the Apple Virtualization framework via swift."
    Write-Information "Install with: xcode-select --install" -InformationAction Continue
    exit 1
}

$swiftSrc = @'
import Foundation
import Virtualization

let minMajor = 26

let sema = DispatchSemaphore(value: 0)
var resolved: (url: URL, build: String, version: String)?
var failureKind: String?
var failureMessage: String?

VZMacOSRestoreImage.fetchLatestSupported { result in
    switch result {
    case .success(let image):
        let v = image.operatingSystemVersion
        let versionString = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        if v.majorVersion < minMajor {
            failureKind = "version-below-floor"
            failureMessage = "Apple's latest published macOS for this host is \(versionString) (build \(image.buildVersion)); macOS \(minMajor)+ is required. The host hardware bucket may need an OS bump (Apple gates macOS 26 IPSWs to host macOS 15+ on M4+)."
        } else {
            resolved = (image.url, image.buildVersion, versionString)
        }
    case .failure(let err):
        let ns = err as NSError
        // VZErrorRestoreImageCatalogLoadFailed = 10001; thrown from the
        // private installation-service helper when its catalog fetch
        // fails. Surfaces as "The restore image catalog failed to
        // load. Installation service returned an unexpected error." --
        // verbatim from the framework, opaque to the operator. Bucket
        // it separately so PowerShell can emit a targeted hint.
        if ns.domain == "VZErrorDomain" && ns.code == 10001 {
            failureKind = "vz-catalog-fetch"
        } else {
            failureKind = "vz-other"
        }
        failureMessage = "\(ns.localizedDescription) (domain=\(ns.domain) code=\(ns.code))"
    }
    sema.signal()
}
sema.wait()

if let kind = failureKind {
    FileHandle.standardError.write(Data("ERROR_KIND=\(kind)\n".utf8))
    FileHandle.standardError.write(Data("Error: \(failureMessage ?? "(no message)")\n".utf8))
    exit(1)
}
guard let r = resolved else {
    FileHandle.standardError.write(Data("ERROR_KIND=vz-other\n".utf8))
    FileHandle.standardError.write(Data("Error: VZMacOSRestoreImage.fetchLatestSupported returned no result\n".utf8))
    exit(1)
}
print("\(r.url.absoluteString)\t\(r.build)\t\(r.version)")
'@

# The VZ probe needs the com.apple.security.virtualization entitlement to
# reach Apple's installation service; Invoke-EntitledSwift compiles and
# self-signs the helper so the call works (a bare `swift <file>` does not).
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force

Write-Verbose "Probing VZMacOSRestoreImage.fetchLatestSupported via swift..."
$resolved = Invoke-EntitledSwift -Source $swiftSrc
if ($LASTEXITCODE -ne 0) {
    $resolvedText = ($resolved -join "`n")
    $errorKind = ($resolved | ForEach-Object { "$_" } |
        Where-Object { $_ -match '^ERROR_KIND=' } |
        Select-Object -Last 1) -replace '^ERROR_KIND=',''
    switch ($errorKind) {
        'vz-catalog-fetch' {
            Write-Error @"
VZMacOSRestoreImage.fetchLatestSupported failed inside Apple's
installation service (VZErrorDomain code 10001, "restore image
catalog failed to load").
"@
            Write-Information @"
To continue, download a macOS 26 IPSW for Apple Virtualization here:
    https://ipsw.me/VirtualMac2,1
Save it as this exact path, then re-run Get-Image.ps1:
    $baseImageFile

Raw VZ output:
$resolvedText
"@ -InformationAction Continue
        }
        'version-below-floor' {
            Write-Error 'Apple published a macOS below 26 as "latest supported" for this host.'
            Write-Information @"
The host probably has an older chip (M3 or earlier) or an older host
OS that Apple has not yet matched to a macOS 26 IPSW bucket. The full
VZ message follows:

$resolvedText
"@ -InformationAction Continue
        }
        default {
            # vz-other or no ERROR_KIND line at all (compiler error,
            # swift crash). The latter is the only case where the
            # Xcode CLT hint is actually relevant.
            Write-Error "VZMacOSRestoreImage probe failed."
            Write-Information @"
$resolvedText
If swift itself errored (compile failure, missing framework), make
sure the host runs macOS 15+ on Apple Silicon and that Xcode command
line tools are present: xcode-select --install
"@ -InformationAction Continue
        }
    }
    exit 1
}

# `swift` prints any compiler warnings on the same stdout as our final
# line; the resolution line is always the LAST tab-separated 3-field
# entry, so pick that one rather than .Trim()-ing the whole capture.
$resolvedLine = ($resolved -split "`n" | Where-Object { ($_ -split "`t").Count -ge 3 } | Select-Object -Last 1)
if (-not $resolvedLine) {
    Write-Error ("VZMacOSRestoreImage probe returned no usable line: " + ($resolved -join "`n"))
    exit 1
}
$fields = $resolvedLine -split "`t"
$sourceUrl  = $fields[0].Trim()
$build      = $fields[1].Trim()
$version    = $fields[2].Trim()
Write-Output "Apple published macOS $version (build $build): $sourceUrl"

# --- REGION: Skip-if-same-source guard
if (Test-DownloadAlreadyCurrent -SourceUrl $sourceUrl -BaseImageFile $baseImageFile -OriginFile $baseImageOrigin) {
    $msg = "Skipping download: $sourceUrl URL and expected size match the prior run for $baseImageFile. To force a re-download, delete or rename: $baseImageFile"
    Write-Information $msg -InformationAction Continue
    Write-Output $msg
    exit 0
}

# --- REGION: Download the IPSW
$downloadFile = Join-Path $downloadDir "downloaded.ipsw"
Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceUrl to $downloadFile (~15-20 GB)..."
try {
    Save-CachedHttpUri -Uri $sourceUrl -OutFile $downloadFile
} catch {
    Write-Error "Download failed: $($_.Exception.Message)"
    exit 1
}
$downloadedSize = (Get-Item -LiteralPath $downloadFile).Length

# --- REGION: Validate the IPSW restore-image headers
# Apple publishes the IPSW URL via the same VZ API that consumes it,
# so a SHA mismatch from a CDN proxy is the only realistic corruption
# mode. VZMacOSRestoreImage.load(from:) parses the IPSW header + verifies
# the embedded signature; on any failure it returns NSError and we
# fail loud rather than ship a broken image to New-VM.ps1.
$validateSrc = @'
import Foundation
import Virtualization

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Error: usage: <ipsw-path>\n".utf8))
    exit(1)
}
let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

let sema = DispatchSemaphore(value: 0)
var failure: String?
var versionString: String?

VZMacOSRestoreImage.load(from: url) { result in
    switch result {
    case .success(let image):
        let v = image.operatingSystemVersion
        versionString = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (build \(image.buildVersion))"
    case .failure(let err):
        failure = err.localizedDescription
    }
    sema.signal()
}
sema.wait()

if let f = failure {
    FileHandle.standardError.write(Data("Error: \(f)\n".utf8))
    exit(1)
}
print("Validated IPSW: macOS \(versionString ?? "?")")
'@

Write-Verbose "Validating downloaded IPSW via VZMacOSRestoreImage.load(from:)..."
$vOut = Invoke-EntitledSwift -Source $validateSrc -ArgumentList @($downloadFile)
if ($LASTEXITCODE -ne 0) {
    Write-Error ("IPSW validation failed: " + ($vOut -join "`n"))
    Remove-Item $downloadFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Output ($vOut -join "`n")

# --- REGION: Preserve previous and finalize
$previousFile = Join-Path $downloadDir "$baseImageName.previous.ipsw"
Remove-Item $previousFile -Force -ErrorAction SilentlyContinue
if (Test-Path $baseImageFile) {
    Move-Item -Path $baseImageFile -Destination $previousFile
    Write-Output "Previous image preserved as: $previousFile"
}
Move-Item -Path $downloadFile -Destination $baseImageFile

# Origin sentinel records the IPSW filename, source URL, and byte count.
# Test-DownloadAlreadyCurrent reads this on the next run to skip an
# identical re-download. The IPSW filename is derived from the URL leaf.
$isoFileName = [System.IO.Path]::GetFileName(([System.Uri]$sourceUrl).LocalPath)
Set-Content -Path $baseImageOrigin -Value @($isoFileName, $sourceUrl, "$downloadedSize")
Write-Output "Recorded source filename, URL, and byte count to: $baseImageOrigin"

Write-Output "Download complete: $baseImageFile"
