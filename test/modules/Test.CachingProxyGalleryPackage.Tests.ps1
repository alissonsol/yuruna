<#PSScriptInfo
.VERSION 2026.11.05
.GUID 429cf6e1-60e6-4291-ada0-b98592faf403
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cache squid store-id powershell-gallery pester
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
    Guards how the caching proxy serves a stored PowerShell Gallery package
    without asking the gallery.
.DESCRIPTION
    The gallery answers a package URL with a 302 to its CDN that squid cannot
    store, so a gallery outage failed every install even with the package in
    the cache. A Store ID files the gallery URL under the CDN object it
    redirects to. squid itself is not available here, so the directives are
    read from the seed, and the rules file -- parsed as cloud-init writes it --
    is applied to the lines squid hands its helper.
    See https://yuruna.link/42f6b05f-005c
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $seed = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data') | ConvertFrom-Yaml
    $script:squidConf = @($seed.write_files | Where-Object { $_.path -eq '/etc/squid/conf.d/yuruna.conf' })[0].content
    $script:rules = @($seed.write_files | Where-Object { $_.path -eq '/etc/squid/yuruna-store-id.rules' })[0].content

    # What storeid_file_rewrite answers for one input line: the first rule whose
    # regex matches, with $1..$n replaced by the captures, or $null for ERR.
    function Get-StoreIdFor {
        param([Parameter(Mandatory)][string]$Line)
        foreach ($rule in @($script:rules -split "`n" | Where-Object { $_ })) {
            $regex, $storeId = $rule -split "`t+", 2
            $match = [regex]::Match($Line, $regex)
            if (-not $match.Success) { continue }
            for ($i = 1; $i -lt $match.Groups.Count; $i++) { $storeId = $storeId.Replace("`$$i", $match.Groups[$i].Value) }
            return $storeId
        }
        return $null
    }

    $script:packageUrl = 'https://www.powershellgallery.com/api/v2/package/powershell-yaml/0.4.12'
    # The CDN location the gallery redirects that URL to.
    $script:cdnUrl = 'https://cdn.powershellgallery.com/packages/powershell-yaml.0.4.12.nupkg'
}

Describe 'squid files a gallery package request under the CDN object' {
    It 'sends only versioned package URLs to the stock store ID helper' {
        $script:squidConf | Should -Match '(?m)^acl yuruna_gallery_package url_regex -i \^https\?://www\\\.powershellgallery\\\.com/api/v2/package/'
        $script:squidConf | Should -Match '(?m)^store_id_program /usr/lib/squid/storeid_file_rewrite /etc/squid/yuruna-store-id\.rules$'
        $script:squidConf.IndexOf('store_id_access allow yuruna_gallery_package') | Should -BeLessThan $script:squidConf.IndexOf('store_id_access deny all') -Because 'store_id_access is first-match-wins'
        $script:squidConf | Should -Match '(?m)^store_id_access deny all$'
    }

    It 'keeps a published package for a year' {
        $script:squidConf | Should -Match '(?m)^refresh_pattern -i \^https\?://cdn\\\.powershellgallery\\\.com/packages/\s+525600 100% 525600 override-expire'
    }

    It 'writes the rules file as one tab-separated rule with no comment line' {
        # The helper reports any line without a tab, a comment included, as a parse error.
        $lines = @($script:rules -split "`n" | Where-Object { $_ })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match "^[^\t]+\t[^\t]+$"
    }
}

Describe 'the store ID rule maps a package URL to the CDN URL it redirects to' {
    It 'maps the line squid sends, with the request details after the URL' {
        Get-StoreIdFor -Line "$($script:packageUrl) 192.168.7.181/- - GET myip=192.168.7.42 myport=3129" | Should -BeExactly $script:cdnUrl
    }

    It 'maps a bare URL and keeps the request scheme' {
        Get-StoreIdFor -Line $script:packageUrl | Should -BeExactly $script:cdnUrl
        Get-StoreIdFor -Line ($script:packageUrl -replace '^https', 'http') | Should -BeExactly ($script:cdnUrl -replace '^https', 'http')
    }

    It 'leaves the <Name> unmapped' -TestCases @(
        @{ Name = 'feed root'; Url = 'https://www.powershellgallery.com/api/v2/' }
        @{ Name = 'package search'; Url = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='powershell-yaml'" }
        @{ Name = 'unversioned package URL'; Url = 'https://www.powershellgallery.com/api/v2/package/' }
        @{ Name = 'CDN object itself'; Url = 'https://cdn.powershellgallery.com/packages/powershell-yaml.0.4.12.nupkg' }
    ) {
        param($Url)
        Get-StoreIdFor -Line "$Url 192.168.7.181/- - GET myip=192.168.7.42 myport=3129" | Should -BeNullOrEmpty
    }

    It 'agrees with the ACL on which URLs reach the helper' {
        $acl = [regex]::Match($script:squidConf, '(?m)^acl yuruna_gallery_package url_regex -i (\S+)$').Groups[1].Value
        foreach ($url in @($script:packageUrl, 'https://www.powershellgallery.com/api/v2/', 'https://www.powershellgallery.com/api/v2/package/',
                'https://cdn.powershellgallery.com/packages/powershell-yaml.0.4.12.nupkg')) {
            ($url -match $acl) | Should -Be ($null -ne (Get-StoreIdFor -Line $url)) -Because $url
        }
    }
}
