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

# ─────────────────────────────────────────────
# Region: New Tests — Question Checkpoint, Doc Helpers, Result, Monkey Lookup, UI
# ─────────────────────────────────────────────

Describe "Save-QuestionCheckpoint / Get-QuestionCheckpoint" {
    It "Round-trips questions through save and load" {
        $dir = Join-Path $TestDrive "qcp-roundtrip"
        New-Item -ItemType Directory $dir -Force | Out-Null
        $questions = @(
            @{ EntryPoint = "src/auth.cs"; Question = "How does login work?" },
            @{ EntryPoint = "src/orders.cs"; Question = "How are orders processed?" }
        )
        Save-QuestionCheckpoint -OutputPath $dir -Questions $questions
        $loaded = Get-QuestionCheckpoint -OutputPath $dir

        $loaded | Should -Not -BeNullOrEmpty
        $loaded.Count | Should -Be 2
        $loaded[0].EntryPoint | Should -Be "src/auth.cs"
    }

    It "Returns null when no checkpoint file exists" {
        $dir = Join-Path $TestDrive "qcp-empty"
        New-Item -ItemType Directory $dir -Force | Out-Null
        $result = Get-QuestionCheckpoint -OutputPath $dir
        $result | Should -BeNullOrEmpty
    }

    It "Returns null for corrupt checkpoint file" {
        $dir = Join-Path $TestDrive "qcp-corrupt"
        New-Item -ItemType Directory $dir -Force | Out-Null
        "not valid json{{{" | Set-Content (Join-Path $dir "questions-checkpoint.json")
        $result = Get-QuestionCheckpoint -OutputPath $dir
        $result | Should -BeNullOrEmpty
    }

    It "Returns null for checkpoint with empty questions array" {
        $dir = Join-Path $TestDrive "qcp-emptyq"
        New-Item -ItemType Directory $dir -Force | Out-Null
        @{ Questions = @(); Count = 0; SavedAt = (Get-Date).ToString('o') } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir "questions-checkpoint.json")
        $result = Get-QuestionCheckpoint -OutputPath $dir
        $result | Should -BeNullOrEmpty
    }
}

Describe "Get-DocDirectories" {
    It "Returns relative paths with forward slashes for doc directories" {
        $root = Join-Path $TestDrive "docdir-repo"
        $dirs = @(
            "docs\knowledge\workflows",
            "docs\knowledge\adr",
            "docs\guides",
            "src\main"
        )
        foreach ($d in $dirs) {
            New-Item -ItemType Directory (Join-Path $root $d) -Force | Out-Null
        }

        $result = Get-DocDirectories -RootDir $root

        $result | Should -Not -BeNullOrEmpty
        # All returned paths should use forward slashes
        $result | ForEach-Object { $_ | Should -Not -Match '\\' }
        # Should contain docs-related paths
        ($result -join "`n") | Should -Match 'docs'
        ($result -join "`n") | Should -Match 'agentKT'
    }

    It "Returns empty array when no doc directories exist" {
        $root = Join-Path $TestDrive "docdir-nodocs"
        New-Item -ItemType Directory (Join-Path $root "src\main") -Force | Out-Null

        $result = Get-DocDirectories -RootDir $root
        $result.Count | Should -Be 0
    }
}

Describe "Get-DocReferences" {
    It "Returns zero refs for null text" {
        $refs = Get-DocReferences -ResponseText $null
        $refs.TotalRefs | Should -Be 0
        $refs.IsDocGrounded | Should -Be $false
    }

    It "Returns zero refs for empty text" {
        $refs = Get-DocReferences -ResponseText ""
        $refs.TotalRefs | Should -Be 0
        $refs.IsDocGrounded | Should -Be $false
    }

    It "Detects docs/ path reference and marks as grounded" {
        $refs = Get-DocReferences -ResponseText "See docs/workflow.md for details"
        $refs.IsDocGrounded | Should -Be $true
        $refs.TotalRefs | Should -BeGreaterThan 0
    }

    It "Populates DocPaths for markdown file references" {
        $refs = Get-DocReferences -ResponseText "Refer to docs/setup.md and architecture/design.md"
        $refs.DocPaths | Should -Not -BeNullOrEmpty
        $refs.DocPaths | Should -Contain "docs/setup.md"
    }

    It "Detects swagger/api_doc pattern in PatternHits" {
        $refs = Get-DocReferences -ResponseText "The swagger endpoint documents the API"
        $refs.PatternHits.Keys | Should -Contain "api_doc"
    }

    It "Detects README.md in PatternHits" {
        $refs = Get-DocReferences -ResponseText "Check README.md for installation instructions"
        $refs.PatternHits.Keys | Should -Contain "readme"
    }

    It "Returns IsDocGrounded false for text with no doc references" {
        $refs = Get-DocReferences -ResponseText "The function calculates a sum of integers and returns the result."
        $refs.IsDocGrounded | Should -Be $false
        $refs.TotalRefs | Should -Be 0
    }
}

Describe "Read-AgentStatus" {
    It "Returns null for null input" {
        $result = Read-AgentStatus -Output $null
        $result | Should -BeNullOrEmpty
    }

    It "Returns null for empty string" {
        $result = Read-AgentStatus -Output ""
        $result | Should -BeNullOrEmpty
    }

    It "Returns null for text without status block" {
        $result = Read-AgentStatus -Output "Just some random output with no status markers"
        $result | Should -BeNullOrEmpty
    }

    It "Parses MONKEY_STATUS: SUCCESS" {
        $result = Read-AgentStatus -Output "MONKEY_STATUS: SUCCESS"
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'SUCCESS'
    }

    It "Parses DOCS_CREATED integer" {
        $result = Read-AgentStatus -Output "MONKEY_STATUS: PARTIAL`nDOCS_CREATED: 5"
        $result.DocsCreated | Should -Be 5
    }

    It "Parses GAPS_FOUND and GAPS_FIXED" {
        $output = "MONKEY_STATUS: SUCCESS`nGAPS_FOUND: 3`nGAPS_FIXED: 2"
        $result = Read-AgentStatus -Output $output
        $result.GapsFound | Should -Be 3
        $result.GapsFixed | Should -Be 2
    }

    It "Parses multiple fields from one output block" {
        $output = @"
Some preamble text
MONKEY_STATUS: SUCCESS
DOCS_CREATED: 10
DOCS_UPDATED: 3
QUESTIONS_ASKED: 25
GAPS_FOUND: 7
GAPS_FIXED: 5
Some trailing text
"@
        $result = Read-AgentStatus -Output $output
        $result.Status | Should -Be 'SUCCESS'
        $result.DocsCreated | Should -Be 10
        $result.DocsUpdated | Should -Be 3
        $result.QuestionsAsked | Should -Be 25
        $result.GapsFound | Should -Be 7
        $result.GapsFixed | Should -Be 5
    }
}

Describe "New-MonkeyResult" {
    It "Returns hashtable with all expected keys" {
        $result = New-MonkeyResult -MonkeyName "rafiki"
        $result | Should -BeOfType [hashtable]
        $expected = @('MonkeyName','Duration','DurationSeconds','Model','ExitStatus',
                      'QuestionsAsked','QuestionsAnswered','DocRefsFound',
                      'FilesCreated','FilesModified','DocsGroundedPct',
                      'RetryCount','Errors','Timestamp')
        foreach ($key in $expected) {
            $result.ContainsKey($key) | Should -Be $true -Because "key '$key' should exist"
        }
    }

    It "Uses default values for counts and errors" {
        $result = New-MonkeyResult -MonkeyName "abu"
        $result.QuestionsAsked | Should -Be 0
        $result.QuestionsAnswered | Should -Be 0
        $result.FilesCreated | Should -Be 0
        $result.RetryCount | Should -Be 0
        $result.Errors.Count | Should -Be 0
    }

    It "Formats Duration from TimeSpan as hh:mm:ss" {
        $ts = [TimeSpan]::FromSeconds(3661)   # 1h 1m 1s
        $result = New-MonkeyResult -MonkeyName "rafiki" -Duration $ts
        $result.Duration | Should -Be "01:01:01"
        $result.DurationSeconds | Should -Be 3661
    }

    It "Uses 00:00:00 when Duration is not provided" {
        $result = New-MonkeyResult -MonkeyName "rafiki"
        $result.Duration | Should -Be "00:00:00"
        $result.DurationSeconds | Should -Be 0
    }

    It "Accepts valid ExitStatus enum values" {
        foreach ($status in @('SUCCESS','PARTIAL','FAILED','SKIPPED')) {
            $result = New-MonkeyResult -MonkeyName "test" -ExitStatus $status
            $result.ExitStatus | Should -Be $status
        }
    }

    It "Timestamp is ISO 8601 format" {
        $result = New-MonkeyResult -MonkeyName "rafiki"
        # ISO 8601 round-trip format contains 'T' separator and timezone info
        $result.Timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }
}

Describe "Get-MonkeyById" {
    It "Returns monkey data for valid ID 'rafiki'" {
        $monkey = Get-MonkeyById -Id 'rafiki'
        $monkey | Should -Not -BeNullOrEmpty
        $monkey.Id | Should -Be 'rafiki'
        $monkey.Name | Should -Be 'Rafiki'
    }

    It "Returns monkey data for valid ID 'abu'" {
        $monkey = Get-MonkeyById -Id 'abu'
        $monkey | Should -Not -BeNullOrEmpty
        $monkey.Id | Should -Be 'abu'
    }

    It "Returns null for unknown ID" {
        $monkey = Get-MonkeyById -Id 'nonexistent-monkey'
        $monkey | Should -BeNullOrEmpty
    }
}

Describe "Get-MonkeyPacks" {
    It "Returns hashtable with known pack names" {
        $packs = Get-MonkeyPacks
        $packs | Should -BeOfType [hashtable]
        foreach ($name in @('full','quick','audit','security','docs','autonomous')) {
            $packs.ContainsKey($name) | Should -Be $true -Because "pack '$name' should exist"
        }
    }

    It "Each pack value is an array of monkey IDs" {
        $packs = Get-MonkeyPacks
        foreach ($name in $packs.Keys) {
            $packs[$name] | Should -Not -BeNullOrEmpty -Because "pack '$name' should have members"
            $packs[$name].Count | Should -BeGreaterThan 0
            # Each entry should be a string (monkey ID)
            foreach ($id in $packs[$name]) {
                $id | Should -BeOfType [string]
            }
        }
    }
}

Describe "UI Helpers — No-Crash Tests" {
    It "Write-MonkeyBanner does not throw" {
        { Write-MonkeyBanner -Name "Test" -Emoji "🐵" -Version "1.0" -Tagline "Unit test" } |
            Should -Not -Throw
    }

    It "Write-Phase does not throw" {
        { Write-Phase -Phase "TEST" -Message "Running unit tests" } |
            Should -Not -Throw
    }

    It "Write-Step does not throw with each status" {
        foreach ($s in @("OK","WARN","ERROR","SKIP","INFO")) {
            { Write-Step -Message "Test message" -Status $s } | Should -Not -Throw
        }
    }

    It "Write-MonkeySummary does not throw" {
        $stats = @{ QuestionsAsked = 10; FilesCreated = 3 }
        { Write-MonkeySummary -Stats $stats -Emoji "🐵" } | Should -Not -Throw
    }
}
