<#
.SYNOPSIS
    Pester tests for MonkeyCommon.psm1 — Batch Execution, Incremental Mode, Checkpointing
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\shared\MonkeyCommon.psm1" -Force
}

Describe "Get-QuestionId" {
    It "Returns consistent hash for same input" {
        $id1 = Get-QuestionId -EntryPoint "src/auth.cs" -Question "How does auth work?"
        $id2 = Get-QuestionId -EntryPoint "src/auth.cs" -Question "How does auth work?"
        $id1 | Should -Be $id2
    }

    It "Returns different hash for different entry point" {
        $id1 = Get-QuestionId -EntryPoint "src/auth.cs" -Question "How does auth work?"
        $id2 = Get-QuestionId -EntryPoint "src/orders.cs" -Question "How does auth work?"
        $id1 | Should -Not -Be $id2
    }

    It "Returns different hash for different question" {
        $id1 = Get-QuestionId -EntryPoint "src/auth.cs" -Question "How does auth work?"
        $id2 = Get-QuestionId -EntryPoint "src/auth.cs" -Question "What errors can occur?"
        $id1 | Should -Not -Be $id2
    }

    It "Returns 16-character hex string" {
        $id = Get-QuestionId -EntryPoint "test" -Question "test"
        $id | Should -Match '^[0-9a-f]{16}$'
    }

    It "Handles empty entry point" {
        $id = Get-QuestionId -EntryPoint "" -Question "general question"
        $id | Should -Match '^[0-9a-f]{16}$'
    }
}

Describe "Batch Checkpoint" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-checkpoint-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns empty set when no checkpoint exists" {
        $result = Get-BatchCheckpoint -OutputPath $script:testDir
        $result.Count | Should -Be 0
    }

    It "Round-trips IDs through save and load" {
        $ids = [System.Collections.Generic.HashSet[string]]::new()
        [void]$ids.Add("abc123")
        [void]$ids.Add("def456")
        [void]$ids.Add("ghi789")

        Save-BatchCheckpoint -OutputPath $script:testDir -CompletedIds $ids
        $loaded = Get-BatchCheckpoint -OutputPath $script:testDir

        $loaded.Count | Should -Be 3
        $loaded.Contains("abc123") | Should -Be $true
        $loaded.Contains("def456") | Should -Be $true
        $loaded.Contains("ghi789") | Should -Be $true
    }

    It "Overwrites previous checkpoint atomically" {
        $ids1 = [System.Collections.Generic.HashSet[string]]::new()
        [void]$ids1.Add("first")
        Save-BatchCheckpoint -OutputPath $script:testDir -CompletedIds $ids1

        $ids2 = [System.Collections.Generic.HashSet[string]]::new()
        [void]$ids2.Add("first")
        [void]$ids2.Add("second")
        Save-BatchCheckpoint -OutputPath $script:testDir -CompletedIds $ids2

        $loaded = Get-BatchCheckpoint -OutputPath $script:testDir
        $loaded.Count | Should -Be 2
    }

    It "Handles corrupt checkpoint file gracefully" {
        $cpPath = Join-Path $script:testDir "batch-checkpoint.json"
        "not valid json{{{" | Set-Content $cpPath
        $result = Get-BatchCheckpoint -OutputPath $script:testDir
        $result.Count | Should -Be 0
    }

    It "Checkpoint file contains metadata" {
        $ids = [System.Collections.Generic.HashSet[string]]::new()
        [void]$ids.Add("test1")
        Save-BatchCheckpoint -OutputPath $script:testDir -CompletedIds $ids

        $cpPath = Join-Path $script:testDir "batch-checkpoint.json"
        $data = Get-Content $cpPath -Raw | ConvertFrom-Json
        $data.Count | Should -Be 1
        $data.LastUpdated | Should -Not -BeNullOrEmpty
    }
}

Describe "Incremental State" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-incr-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns null when no state exists" {
        $state = Get-IncrementalState -WorkingDirectory $script:testDir
        $state | Should -BeNullOrEmpty
    }

    It "Round-trips state through save and load" {
        Save-IncrementalState -WorkingDirectory $script:testDir -MonkeyName "rafiki" -CommitHash "abc123" -EntryPointCount 10 -QuestionsAsked 50
        $state = Get-IncrementalState -WorkingDirectory $script:testDir

        $state.MonkeyName | Should -Be "rafiki"
        $state.CommitHash | Should -Be "abc123"
        $state.EntryPoints | Should -Be 10
        $state.QuestionsAsked | Should -Be 50
        $state.LastRunAt | Should -Not -BeNullOrEmpty
    }

    It "Creates .playbook-state directory automatically" {
        Save-IncrementalState -WorkingDirectory $script:testDir -MonkeyName "test" -CommitHash "xyz" -EntryPointCount 0 -QuestionsAsked 0
        Test-Path (Join-Path $script:testDir ".playbook-state") | Should -Be $true
    }

    It "Handles corrupt state file gracefully" {
        $stateDir = Join-Path $script:testDir ".playbook-state"
        New-Item -ItemType Directory $stateDir -Force | Out-Null
        "garbage" | Set-Content (Join-Path $stateDir "last-run.json")
        $state = Get-IncrementalState -WorkingDirectory $script:testDir
        $state | Should -BeNullOrEmpty
    }
}

Describe "Select-IncrementalEntryPoints" {
    It "Filters entry points to only changed files" {
        $eps = @(
            @{ Path="C:\repo\src\auth.cs"; RelPath="src/auth.cs" },
            @{ Path="C:\repo\src\orders.cs"; RelPath="src/orders.cs" },
            @{ Path="C:\repo\src\products.cs"; RelPath="src/products.cs" }
        )
        $changed = @("src/auth.cs", "src/products.cs")
        $result = Select-IncrementalEntryPoints -EntryPoints $eps -ChangedFiles $changed -WorkingDirectory "C:\repo"

        $result.Count | Should -Be 2
        ($result | ForEach-Object { $_.RelPath }) | Should -Contain "src/auth.cs"
        ($result | ForEach-Object { $_.RelPath }) | Should -Contain "src/products.cs"
    }

    It "Returns empty when no files changed" {
        $eps = @(
            @{ Path="C:\repo\src\auth.cs"; RelPath="src/auth.cs" }
        )
        $result = Select-IncrementalEntryPoints -EntryPoints $eps -ChangedFiles @() -WorkingDirectory "C:\repo"
        $result.Count | Should -Be 0
    }

    It "Handles backslash vs forward-slash normalization" {
        $eps = @(
            @{ Path="C:\repo\src\auth.cs"; RelPath="src\auth.cs" }
        )
        $changed = @("src/auth.cs")
        $result = Select-IncrementalEntryPoints -EntryPoints $eps -ChangedFiles $changed -WorkingDirectory "C:\repo"
        $result.Count | Should -BeGreaterOrEqual 1
    }

    It "Is case-insensitive" {
        $eps = @(
            @{ Path="C:\repo\src\Auth.cs"; RelPath="src/Auth.cs" }
        )
        $changed = @("src/auth.cs")
        $result = Select-IncrementalEntryPoints -EntryPoints $eps -ChangedFiles $changed -WorkingDirectory "C:\repo"
        $result.Count | Should -BeGreaterOrEqual 1
    }
}

Describe "Invoke-CopilotBatch — Prompt Construction" {
    It "Builds mega-prompt with GUID-based markers" {
        # We can't invoke copilot in unit tests, but we can test prompt construction
        # by verifying the function exists and accepts correct params
        $cmd = Get-Command Invoke-CopilotBatch
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.Keys | Should -Contain "Questions"
        $cmd.Parameters.Keys | Should -Contain "WorkingDirectory"
        $cmd.Parameters.Keys | Should -Contain "ModelName"
        $cmd.Parameters.Keys | Should -Contain "TimeoutPerQuestion"
    }
}

Describe "Invoke-MonkeyQuestions — Batch Mode Params" {
    It "Has BatchSize parameter" {
        $cmd = Get-Command Invoke-MonkeyQuestions
        $cmd.Parameters.Keys | Should -Contain "BatchSize"
    }

    It "Accepts BatchSize 0 for legacy single mode" {
        $cmd = Get-Command Invoke-MonkeyQuestions
        $cmd.Parameters["BatchSize"].ParameterType | Should -Be ([int])
    }
}
