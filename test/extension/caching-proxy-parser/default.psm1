<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456824
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    Default caching-proxy-parser extension: VM-side Go tail-server for
    the squid-cache "Recent 100 requests" view.

.DESCRIPTION
    Replaces loki + promtail for that one panel. The bulk of the
    extension is the Go source under this folder (main.go,
    caching-proxy-parser.service); both get fetched + built + installed
    by the squid-cache VM's cloud-init user-data on first boot.

    Nothing runs on the harness host -- this module exposes a single
    metadata helper so other harness code (and the operator) can
    discover where the source lives and which port the running service
    listens on. The runner doesn't dispatch to the caching-proxy-parser
    area today; the extension is here so the source files have an
    obvious home that follows the existing extension/<area>/ shape.
#>

<#
.SYNOPSIS
    Returns metadata about the caching-proxy-parser extension: its
    source-file list (relative to test/extension/caching-proxy-parser/),
    the listen port baked into the systemd unit, and the URL path
    surfaces the running service exposes.
.DESCRIPTION
    Used as a self-describing hook by the squid-cache New-VM templating
    step + by anyone wanting to confirm the source tree on disk before
    a cycle starts. Pure data -- no I/O, no side effects.
#>
function Get-CachingProxyParserManifest {
    [CmdletBinding()]
    [OutputType([Hashtable])]
    param()
    return @{
        SourceFiles = @(
            'main.go',
            'go.mod',
            'caching-proxy-parser.service'
        )
        ListenPort  = 9302
        Endpoints   = @{
            Html   = '/'
            Json   = '/recent-requests'
            Health = '/healthz'
        }
        InstallPath = '/usr/local/bin/caching-proxy-parser'
        ServicePath = '/etc/systemd/system/caching-proxy-parser.service'
    }
}

Export-ModuleMember -Function Get-CachingProxyParserManifest
