<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42bab3ac-38fb-4688-a3a4-990903db1a23
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Yuruna.CachingProxySeed.psm1') -Force
    $script:Parent = Join-Path $TestDrive vm
    $null = New-Item -ItemType Directory -Path $script:Parent
}

Describe 'Caching-proxy seed secrets remain protected throughout construction' {
    It 'creates distinct empty staging directories without reusing prior builds' {
        $first = New-CachingProxySeedWorkspace $script:Parent
        $second = New-CachingProxySeedWorkspace $script:Parent
        try {
            $first.Root | Should -Not -Be $second.Root
            @(Get-ChildItem $first.Source).Count | Should -Be 0
            (Split-Path -Parent $first.Root) | Should -Be $script:Parent
        } finally {
            Remove-CachingProxySeedWorkspace $first -Confirm:$false
            Remove-CachingProxySeedWorkspace $second -Confirm:$false
        }
    }

    It 'refuses a colliding staging name without reusing its contents' {
        $collision = Join-Path $script:Parent ('.yuruna-cache-seed-' + ('a' * 32))
        $null = New-Item -ItemType Directory -Path $collision
        [IO.File]::WriteAllText((Join-Path $collision sentinel), 'existing')
        InModuleScope Yuruna.CachingProxySeed -Parameters @{ Parent = $script:Parent; Collision = $collision } {
            param($Parent, $Collision)
            $script:CollisionParent = $Parent
            $script:CollisionPath = $Collision
            Mock Join-Path { $script:CollisionPath } -ParameterFilter { $ChildPath -like '.yuruna-cache-seed-*' }
            { New-CachingProxySeedWorkspace $script:CollisionParent } | Should -Throw '*already exists*'
        }
        [IO.File]::ReadAllText((Join-Path $collision sentinel)) | Should -Be 'existing'
    }

    It 'cleans plaintext and an incomplete image after a generator failure' {
        $workspace = New-CachingProxySeedWorkspace $script:Parent
        $oldImage = Join-Path $script:Parent seed.iso
        [IO.File]::WriteAllText($oldImage, 'previous image')
        try {
            try {
                [IO.File]::WriteAllText((Join-Path $workspace.Source user-data), 'sentinel-secret')
                [IO.File]::WriteAllText($workspace.Image, 'partial-secret-image')
                throw 'generator failed'
            } finally { Remove-CachingProxySeedWorkspace $workspace -Confirm:$false }
        } catch { $_.Exception.Message | Should -Be 'generator failed' }
        Test-Path $workspace.Root | Should -BeFalse
        [IO.File]::ReadAllText($oldImage) | Should -Be 'previous image'
    }

    It 'publishes complete protected bytes and removes the temporary source' {
        $workspace = New-CachingProxySeedWorkspace $script:Parent
        $image = Join-Path $script:Parent seed.iso
        try {
            [IO.File]::WriteAllText($workspace.Image, 'complete image')
            Publish-CachingProxySeedImage $workspace $image -Confirm:$false
            [IO.File]::ReadAllText($image) | Should -Be 'complete image'
            Test-Path $workspace.Image | Should -BeFalse
        } finally { Remove-CachingProxySeedWorkspace $workspace -Confirm:$false }
        Test-Path $workspace.Root | Should -BeFalse
    }

    It 'refuses publication outside the staging filesystem directory' {
        $workspace = New-CachingProxySeedWorkspace $script:Parent
        try {
            [IO.File]::WriteAllText($workspace.Image, 'secret')
            { Publish-CachingProxySeedImage $workspace (Join-Path $TestDrive outside.iso) -Confirm:$false } |
                Should -Throw '*staging filesystem*'
            Test-Path (Join-Path $TestDrive outside.iso) | Should -BeFalse
        } finally { Remove-CachingProxySeedWorkspace $workspace -Confirm:$false }
    }

    It 'refuses to clean an unrelated directory described as a workspace' {
        { Remove-CachingProxySeedWorkspace @{ Root = $script:Parent; Parent = $TestDrive } -Confirm:$false } |
            Should -Throw '*unrecognized*'
        Test-Path $script:Parent | Should -BeTrue
    }

    It 'wires protected staging and finally cleanup into every caching-proxy builder' {
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        foreach ($platform in @('ubuntu.kvm', 'macos.utm', 'windows.hyper-v')) {
            $path = Join-Path $root "host/$platform/guest.caching-proxy-service/New-VM.ps1"
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0
            $protected = @($ast.FindAll({ param($node)
                        $node -is [Management.Automation.Language.TryStatementAst] -and
                        $node.Body.Extent.Text -match 'New-CachingProxySeedWorkspace' -and
                        $node.Finally.Extent.Text -match 'Remove-CachingProxySeedWorkspace'
                    }, $true))
            $protected.Count | Should -Be 1
            $protected[0].Body.Extent.Text | Should -Match 'Publish-CachingProxySeedImage'
        }
    }
}

if (-not $IsWindows) {
    Describe 'Unix seed filesystem boundaries' {
        It 'sets private staging before writing and private ISO mode before publication' {
            $workspace = New-CachingProxySeedWorkspace $script:Parent
            $parentMode = [IO.File]::GetUnixFileMode($script:Parent)
            try {
                [int][IO.File]::GetUnixFileMode($workspace.Root) | Should -Be 448
                [IO.File]::WriteAllText($workspace.Image, 'secret')
                $image = Join-Path $script:Parent protected.iso
                Publish-CachingProxySeedImage $workspace $image -Confirm:$false
                [int][IO.File]::GetUnixFileMode($image) | Should -Be 384
                [IO.File]::GetUnixFileMode($script:Parent) | Should -Be $parentMode
            } finally { Remove-CachingProxySeedWorkspace $workspace -Confirm:$false }
        }

        It 'refuses symlink parents and destinations without changing their targets' {
            $link = Join-Path $TestDrive linked-parent
            $null = New-Item -ItemType SymbolicLink -Path $link -Target $script:Parent
            { New-CachingProxySeedWorkspace $link } | Should -Throw '*real directory*'
            $workspace = New-CachingProxySeedWorkspace $script:Parent
            try {
                $target = Join-Path $TestDrive unrelated
                [IO.File]::WriteAllText($target, 'unrelated')
                $destination = Join-Path $script:Parent linked.iso
                $null = New-Item -ItemType SymbolicLink -Path $destination -Target $target
                [IO.File]::WriteAllText($workspace.Image, 'secret')
                { Publish-CachingProxySeedImage $workspace $destination -Confirm:$false } | Should -Throw '*symbolic link*'
                [IO.File]::ReadAllText($target) | Should -Be 'unrelated'
            } finally { Remove-CachingProxySeedWorkspace $workspace -Confirm:$false }
        }
    }
} else {
    Describe 'Windows seed ACL boundaries' {
        It 'protects staging at creation and grants no ordinary-user inherited access' {
            $workspace = New-CachingProxySeedWorkspace $script:Parent
            try {
                $acl = Get-Acl -LiteralPath $workspace.Root
                $acl.AreAccessRulesProtected | Should -BeTrue
                $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
                foreach ($rule in $acl.Access) {
                    $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value | Should -BeIn $allowed
                }
            } finally { Remove-CachingProxySeedWorkspace $workspace -Confirm:$false }
        }

        It 'retains an explicit protected ISO ACL after atomic publication' {
            $workspace = New-CachingProxySeedWorkspace $script:Parent
            try {
                [IO.File]::WriteAllText($workspace.Image, 'secret')
                $image = Join-Path $script:Parent protected.iso
                Publish-CachingProxySeedImage $workspace $image -Confirm:$false
                (Get-Acl -LiteralPath $image).AreAccessRulesProtected | Should -BeTrue
                @((Get-Acl -LiteralPath $image).Access | Where-Object IsInherited).Count | Should -Be 0
            } finally { Remove-CachingProxySeedWorkspace $workspace -Confirm:$false }
        }
    }
}
