# ─────────────────────────────────────────────
# RunCheckpoint.Tests.ps1 — Tests for orchestrator-level checkpoint/resume
# ─────────────────────────────────────────────

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1") -Force
}

Describe "Get-RunCheckpointPath" {
    It "Returns path under output root" {
        $path = Get-RunCheckpointPath -OutputRoot "C:\temp\output"
        $path | Should -Be "C:\temp\output\run-checkpoint.json"
    }
}

Describe "Save-RunCheckpoint" {
    BeforeEach {
        $testDir = Join-Path $TestDrive "checkpoint-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    It "Creates checkpoint file with schema version" {
        $data = @{
            startedAt = (Get-Date).ToString('o')
            model     = 'test-model'
            monkeys   = @{}
        }
        Save-RunCheckpoint -OutputRoot $testDir -CheckpointData $data

        $cpPath = Join-Path $testDir "run-checkpoint.json"
        Test-Path $cpPath | Should -BeTrue

        $loaded = Get-Content $cpPath -Raw | ConvertFrom-Json
        $loaded.schemaVersion | Should -Be 1
        $loaded.model | Should -Be 'test-model'
    }

    It "Atomic write — no .tmp file left behind" {
        $data = @{ startedAt = (Get-Date).ToString('o'); monkeys = @{} }
        Save-RunCheckpoint -OutputRoot $testDir -CheckpointData $data

        $tmpPath = Join-Path $testDir "run-checkpoint.json.tmp"
        Test-Path $tmpPath | Should -BeFalse
    }

    It "Overwrites existing checkpoint" {
        $data1 = @{ startedAt = (Get-Date).ToString('o'); model = 'v1'; monkeys = @{} }
        Save-RunCheckpoint -OutputRoot $testDir -CheckpointData $data1

        $data2 = @{ startedAt = (Get-Date).ToString('o'); model = 'v2'; monkeys = @{} }
        Save-RunCheckpoint -OutputRoot $testDir -CheckpointData $data2

        $loaded = Get-Content (Join-Path $testDir "run-checkpoint.json") -Raw | ConvertFrom-Json
        $loaded.model | Should -Be 'v2'
    }
}

Describe "Get-RunCheckpoint" {
    BeforeEach {
        $testDir = Join-Path $TestDrive "cp-read-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    It "Returns null when no checkpoint exists" {
        $result = Get-RunCheckpoint -OutputRoot $testDir
        $result | Should -BeNullOrEmpty
    }

    It "Returns checkpoint data when valid" {
        $data = @{
            schemaVersion = 1
            startedAt     = (Get-Date).ToString('o')
            model         = 'claude-sonnet-4'
            monkeys       = @{ rafiki = @{ status = 'complete' } }
        }
        $data | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $testDir "run-checkpoint.json") -Encoding UTF8

        $result = Get-RunCheckpoint -OutputRoot $testDir
        $result | Should -Not -BeNullOrEmpty
        $result.model | Should -Be 'claude-sonnet-4'
    }

    It "Returns null for wrong schema version" {
        $data = @{
            schemaVersion = 99
            startedAt     = (Get-Date).ToString('o')
            monkeys       = @{}
        }
        $data | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $testDir "run-checkpoint.json") -Encoding UTF8

        $result = Get-RunCheckpoint -OutputRoot $testDir
        $result | Should -BeNullOrEmpty
    }

    It "Returns null for expired checkpoint" {
        $expiredDate = (Get-Date).AddDays(-10).ToString('o')
        $json = "{`"schemaVersion`":1,`"startedAt`":`"$expiredDate`",`"monkeys`":{}}"
        Set-Content (Join-Path $testDir "run-checkpoint.json") -Value $json -Encoding UTF8

        $result = Get-RunCheckpoint -OutputRoot $testDir -MaxAgeDays 7
        $result | Should -BeNullOrEmpty
    }

    It "Returns checkpoint within age limit" {
        $recentDate = (Get-Date).AddDays(-3).ToString('o')
        $json = "{`"schemaVersion`":1,`"startedAt`":`"$recentDate`",`"monkeys`":{}}"
        Set-Content (Join-Path $testDir "run-checkpoint.json") -Value $json -Encoding UTF8

        $result = Get-RunCheckpoint -OutputRoot $testDir -MaxAgeDays 7
        $result | Should -Not -BeNullOrEmpty
    }

    It "Returns null for corrupt JSON" {
        Set-Content (Join-Path $testDir "run-checkpoint.json") -Value "{{not valid json" -Encoding UTF8

        $result = Get-RunCheckpoint -OutputRoot $testDir
        $result | Should -BeNullOrEmpty
    }
}

Describe "Test-RunCheckpointCompatible" {
    It "Compatible when all params match" {
        $cp = [PSCustomObject]@{
            model    = 'claude-sonnet-4'
            pack     = 'full'
            branch   = 'monkey-army/test'
            repoPath = 'C:\Repo\Test'
        }

        $result = Test-RunCheckpointCompatible -Checkpoint $cp `
            -Model 'claude-sonnet-4' -Pack 'full' -Branch 'monkey-army/test' -WorkDir 'C:\Repo\Test'

        $result.Compatible | Should -BeTrue
        $result.Reasons.Count | Should -Be 0
    }

    It "Incompatible when model differs" {
        $cp = [PSCustomObject]@{ model = 'claude-sonnet-4'; pack = 'full'; branch = 'test'; repoPath = 'C:\' }
        $result = Test-RunCheckpointCompatible -Checkpoint $cp -Model 'claude-opus-4.7' -Pack 'full' -Branch 'test' -WorkDir 'C:\'

        $result.Compatible | Should -BeFalse
        $result.Reasons | Should -Contain "Model changed: claude-sonnet-4 → claude-opus-4.7"
    }

    It "Incompatible when pack differs" {
        $cp = [PSCustomObject]@{ model = 'm'; pack = 'full'; branch = 'b'; repoPath = 'C:\' }
        $result = Test-RunCheckpointCompatible -Checkpoint $cp -Model 'm' -Pack 'audit' -Branch 'b' -WorkDir 'C:\'

        $result.Compatible | Should -BeFalse
        $result.Reasons | Should -Contain "Pack changed: full → audit"
    }

    It "Incompatible when branch differs" {
        $cp = [PSCustomObject]@{ model = 'm'; pack = 'p'; branch = 'old-branch'; repoPath = 'C:\' }
        $result = Test-RunCheckpointCompatible -Checkpoint $cp -Model 'm' -Pack 'p' -Branch 'new-branch' -WorkDir 'C:\'

        $result.Compatible | Should -BeFalse
        $result.Reasons | Should -Contain "Branch changed: old-branch → new-branch"
    }

    It "Reports multiple incompatibilities" {
        $cp = [PSCustomObject]@{ model = 'a'; pack = 'b'; branch = 'c'; repoPath = 'C:\old' }
        $result = Test-RunCheckpointCompatible -Checkpoint $cp -Model 'x' -Pack 'y' -Branch 'z' -WorkDir 'C:\new'

        $result.Compatible | Should -BeFalse
        $result.Reasons.Count | Should -Be 4
    }

    It "Ignores null/empty checkpoint fields" {
        $cp = [PSCustomObject]@{ model = $null; pack = $null; branch = $null; repoPath = $null }
        $result = Test-RunCheckpointCompatible -Checkpoint $cp -Model 'any' -Pack 'any' -Branch 'any' -WorkDir 'C:\'

        $result.Compatible | Should -BeTrue
    }
}

Describe "Remove-RunCheckpoint" {
    It "Removes existing checkpoint file" {
        $testDir = Join-Path $TestDrive "cp-remove-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        $cpPath = Join-Path $testDir "run-checkpoint.json"
        "test" | Set-Content $cpPath
        Test-Path $cpPath | Should -BeTrue

        Remove-RunCheckpoint -OutputRoot $testDir
        Test-Path $cpPath | Should -BeFalse
    }

    It "Does not error when checkpoint does not exist" {
        $testDir = Join-Path $TestDrive "cp-remove-noexist-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        { Remove-RunCheckpoint -OutputRoot $testDir } | Should -Not -Throw
    }
}

Describe "Show-RunCheckpointSummary" {
    It "Handles hashtable monkeys without error" {
        $cp = [PSCustomObject]@{
            startedAt = (Get-Date).ToString('o')
            model     = 'test'
            pack      = 'full'
            branch    = 'test-branch'
            monkeys   = @{
                rafiki = @{ status = 'complete'; completedAt = (Get-Date).ToString('o') }
                abu    = @{ status = 'in-progress' }
                mojo   = @{ status = 'pending' }
            }
        }
        { Show-RunCheckpointSummary -Checkpoint $cp } | Should -Not -Throw
    }

    It "Handles PSCustomObject monkeys from JSON" {
        $json = @{
            startedAt = (Get-Date).ToString('o')
            model     = 'test'
            pack      = 'full'
            branch    = 'b'
            monkeys   = @{
                rafiki = @{ status = 'complete'; completedAt = '2026-01-01T00:00:00' }
            }
        } | ConvertTo-Json -Depth 5

        $cp = $json | ConvertFrom-Json
        { Show-RunCheckpointSummary -Checkpoint $cp } | Should -Not -Throw
    }
}

Describe "End-to-end checkpoint lifecycle" {
    It "Save → Read → Validate → Remove" {
        $testDir = Join-Path $TestDrive "e2e-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        # Save
        $data = @{
            startedAt = (Get-Date).ToString('o')
            model     = 'claude-sonnet-4'
            pack      = 'full'
            batchSize = 5
            branch    = 'monkey-army/test'
            repoPath  = 'C:\Repo\Test'
            monkeys   = @{
                rafiki = @{ status = 'complete'; completedAt = (Get-Date).ToString('o'); result = @{ ExitStatus = 'SUCCESS'; QuestionsAsked = 10; QuestionsAnswered = 8 } }
                abu    = @{ status = 'in-progress'; startedAt = (Get-Date).ToString('o') }
            }
        }
        Save-RunCheckpoint -OutputRoot $testDir -CheckpointData $data

        # Read
        $loaded = Get-RunCheckpoint -OutputRoot $testDir
        $loaded | Should -Not -BeNullOrEmpty
        $loaded.model | Should -Be 'claude-sonnet-4'

        # Validate compatible
        $compat = Test-RunCheckpointCompatible -Checkpoint $loaded `
            -Model 'claude-sonnet-4' -Pack 'full' -Branch 'monkey-army/test' -WorkDir 'C:\Repo\Test'
        $compat.Compatible | Should -BeTrue

        # Validate incompatible
        $compat2 = Test-RunCheckpointCompatible -Checkpoint $loaded `
            -Model 'gpt-4' -Pack 'full' -Branch 'monkey-army/test' -WorkDir 'C:\Repo\Test'
        $compat2.Compatible | Should -BeFalse

        # Remove
        Remove-RunCheckpoint -OutputRoot $testDir
        $gone = Get-RunCheckpoint -OutputRoot $testDir
        $gone | Should -BeNullOrEmpty
    }
}
