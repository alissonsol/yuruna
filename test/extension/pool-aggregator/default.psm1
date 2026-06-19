<#PSScriptInfo
.VERSION 2026.06.19
.GUID 42d5e6f7-a8b9-4c01-9234-ef6789012abc
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
    Default pool-aggregator extension: the VM-side Go pull-collector that
    powers the multi-host pool view (Phase 1, docs/opportunities-hostpool.md).

.DESCRIPTION
    The bulk of the extension is the Go source under this folder (main.go,
    pool-aggregator.service); both get fetched + built + installed on the
    caching-proxy VM (the pool services host) by that VM's cloud-init user-data
    on first boot -- the same mechanism as caching-proxy-parser.

    Nothing runs on the harness host. This module exposes a single metadata
    helper so harness code (and the operator) can discover where the source
    lives, which port the running service listens on, and its endpoints. Pure
    data -- no I/O, no side effects.
#>

<#
.SYNOPSIS
    Returns metadata about the pool-aggregator extension: its source-file list
    (relative to test/extension/pool-aggregator/), the listen port baked into
    the systemd unit, and the URL paths the running service exposes.
.DESCRIPTION
    Self-describing hook; keep ListenPort in sync with main.go, the .service
    unit, the Prometheus scrape target, and the README.
#>
function Get-PoolAggregatorManifest {
    [CmdletBinding()]
    [OutputType([Hashtable])]
    param()
    return @{
        SourceFiles = @(
            'main.go',
            'go.mod',
            'pool-aggregator.service'
        )
        ListenPort  = 9400
        Endpoints   = @{
            Health = '/healthz'
            Metrics = '/metrics'
            Status = '/api/v1/pool-status'
        }
        InstallPath = '/usr/local/bin/pool-aggregator'
        ServicePath = '/etc/systemd/system/pool-aggregator.service'
        # Pool members are auto-discovered from the squid access log + a status
        # probe -- no static host list. Identity is the stable hostId, so a
        # DHCP-served LAN (changing / reused IPs) collapses to one member.
        DiscoverFrom = '/var/log/squid/yuruna_access.log'
        StatusProbePort = 8080
    }
}

Export-ModuleMember -Function Get-PoolAggregatorManifest
