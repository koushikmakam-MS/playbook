<#
.SYNOPSIS
    Pester tests for GitProviders.psm1 — Pluggable Git Provider Layer
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\shared\GitProviders.psm1" -Force
}

Describe "Get-GitProvider" {
    Context "URL-based detection" {
        It "Returns 'ado' for dev.azure.com URLs" {
            Get-GitProvider -RemoteUrl 'https://dev.azure.com/myorg/myproject/_git/myrepo' | Should -Be 'ado'
        }

        It "Returns 'ado' for visualstudio.com URLs" {
            Get-GitProvider -RemoteUrl 'https://myorg.visualstudio.com/myproject/_git/myrepo' | Should -Be 'ado'
        }

        It "Returns 'github' for github.com URLs" {
            Get-GitProvider -RemoteUrl 'https://github.com/owner/repo.git' | Should -Be 'github'
        }

        It "Returns 'gitlab' for gitlab.com URLs" {
            Get-GitProvider -RemoteUrl 'https://gitlab.com/group/project.git' | Should -Be 'gitlab'
        }

        It "Returns 'git' for unknown URLs" {
            Get-GitProvider -RemoteUrl 'https://bitbucket.org/owner/repo.git' | Should -Be 'git'
        }

        It "Returns 'git' when no URL and no WorkingDirectory" {
            Get-GitProvider | Should -Be 'git'
        }
    }

    Context "Override parameter" {
        It "Accepts valid override '<Value>'" -ForEach @(
            @{ Value = 'ado' }
            @{ Value = 'github' }
            @{ Value = 'gitlab' }
            @{ Value = 'git' }
        ) {
            Get-GitProvider -Override $Value | Should -Be $Value
        }

        It "Throws on invalid override value" {
            { Get-GitProvider -Override 'bitbucket' } | Should -Throw "*Invalid git provider*"
        }

        It "Override takes precedence over URL" {
            Get-GitProvider -RemoteUrl 'https://github.com/owner/repo.git' -Override 'ado' | Should -Be 'ado'
        }
    }
}

Describe "Test-GitAuth" {
    Context "git (local-only) provider" {
        It "Returns Authenticated=true for 'git' provider" {
            $result = Test-GitAuth -Provider 'git'
            $result.Authenticated | Should -BeTrue
        }

        It "Returns User='local-only' for 'git' provider" {
            $result = Test-GitAuth -Provider 'git'
            $result.User | Should -Be 'local-only'
        }

        It "Returns Tool='git' for 'git' provider" {
            $result = Test-GitAuth -Provider 'git'
            $result.Tool | Should -Be 'git'
        }
    }

    Context "Parameter validation" {
        It "Provider parameter is mandatory" {
            (Get-Command Test-GitAuth).Parameters['Provider'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -BeTrue
        }
    }
}

Describe "Select-ModelForRepo" {
    Context "UserOverride" {
        It "Returns the override when specified" {
            Select-ModelForRepo -SizeTier 'small' -UserOverride 'my-custom-model' | Should -Be 'my-custom-model'
        }
    }

    Context "Size tier mapping (prompt mode)" {
        It "Returns an array of models for 'small' tier" {
            $result = Select-ModelForRepo -SizeTier 'small'
            $result | Should -Contain 'claude-sonnet-4'
            $result | Should -Contain 'gpt-4.1'
        }

        It "Returns an array of models for 'medium' tier" {
            $result = Select-ModelForRepo -SizeTier 'medium'
            $result | Should -Contain 'claude-sonnet-4'
            $result | Should -Contain 'claude-opus-4.7'
        }

        It "Returns an array of models for 'large' tier" {
            $result = Select-ModelForRepo -SizeTier 'large'
            $result | Should -Contain 'claude-opus-4.7'
            $result | Should -Contain 'claude-sonnet-4'
        }

        It "Returns default models for unknown tier" {
            $result = Select-ModelForRepo -SizeTier 'huge'
            $result | Should -Contain 'claude-sonnet-4'
            $result | Should -Contain 'gpt-4.1'
        }
    }

    Context "Agent mode" {
        It "Returns agent-optimized models for 'small' tier" {
            $result = Select-ModelForRepo -SizeTier 'small' -Mode 'agent'
            $result | Should -Contain 'claude-sonnet-4.5'
        }

        It "Returns agent-optimized models for 'medium' tier" {
            $result = Select-ModelForRepo -SizeTier 'medium' -Mode 'agent'
            $result | Should -Contain 'claude-opus-4.7'
            $result | Should -Contain 'claude-sonnet-4.5'
        }

        It "Returns agent-optimized models for 'large' tier" {
            $result = Select-ModelForRepo -SizeTier 'large' -Mode 'agent'
            $result | Should -Contain 'claude-opus-4.6-1m'
            $result | Should -Contain 'claude-opus-4.7'
        }
    }
}
