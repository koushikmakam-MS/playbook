<#
.SYNOPSIS
    Pester tests for RetrofitHelpers.psm1 and Run-Retrofit.ps1
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\shared\DocLayers.psm1" -Force
    Import-Module "$PSScriptRoot\..\shared\DocRegistry.psm1" -Force
    Import-Module "$PSScriptRoot\..\shared\CompletenessGate.psm1" -Force
    Import-Module "$PSScriptRoot\..\shared\RetrofitHelpers.psm1" -Force

    # ═══════════════════════════════════════════════════════════════
    # HELPER: Create a realistic temp repo structure
    # ═══════════════════════════════════════════════════════════════

    function New-TestRepo {
        param(
            [switch]$Full,          # Full playbook output (score >= 3)
            [switch]$Partial,       # Partial (score 2)
            [switch]$Empty          # Empty repo (score 0)
        )

        $root = Join-Path $TestDrive "repo-$(Get-Random)"
        New-Item $root -ItemType Directory -Force | Out-Null

        if ($Empty) { return $root }

        if ($Partial -or $Full) {
            # Signal 1: copilot-instructions.md
            $ghDir = Join-Path $root ".github"
            New-Item $ghDir -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $ghDir "copilot-instructions.md") -Value ("# Instructions`n" + ("x" * 600)) -Encoding UTF8

            # Signal: 1 workflow doc (not enough for signal 3 threshold of 3)
            $docsDir = Join-Path $root "docs" "knowledge"
            $wfDir = Join-Path $docsDir "workflows"
            New-Item $wfDir -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $wfDir "01_UserAuth.md") -Value "# User Auth Workflow`n## 1. Overview`nSome content" -Encoding UTF8
        }

        if ($Full) {
            $docsDir = Join-Path $root "docs" "knowledge"
            $wfDir = Join-Path $docsDir "workflows"

            # Signal 2: Discovery_Manifest.md
            $manifestContent = @"
# Discovery Manifest

## Identified Domains

| # | Domain Name | Entry Points | Shared Impl | Doc Type | Workflow Doc |
|---|-------------|-------------|-------------|----------|--------------|
| 1 | User Auth | ``AuthController.cs`` | ``AuthService.cs`` | workflow | ``workflows/01_UserAuth.md`` |
| 2 | Payments | ``PaymentController.cs`` | ``PaymentService.cs`` | workflow | ``workflows/02_Payments.md`` |
"@
            Set-Content (Join-Path $docsDir "Discovery_Manifest.md") -Value $manifestContent -Encoding UTF8

            # Signal 3: >= 3 workflow docs
            Set-Content (Join-Path $wfDir "02_Payments.md") -Value "# Payments Workflow`n## 1. Overview`nPayment flow" -Encoding UTF8
            Set-Content (Join-Path $wfDir "03_Notifications.md") -Value "# Notifications Workflow`n## 1. Overview`nNotify users" -Encoding UTF8

            # Signal 4: doc_registry.md
            Set-Content (Join-Path $docsDir "doc_registry.md") -Value "# Doc Registry`nPlaceholder" -Encoding UTF8

            # Signal 5: skills
            $skillsDir = Join-Path $root ".github" "skills"
            New-Item $skillsDir -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $skillsDir "coding.md") -Value "# Coding Skill" -Encoding UTF8

            # Additional docs for layer variety
            Set-Content (Join-Path $docsDir "Architecture_Memory.md") -Value "# Architecture`nDesign decisions" -Encoding UTF8
            Set-Content (Join-Path $docsDir "Glossary.md") -Value "# Glossary`nTerms" -Encoding UTF8

            # Source code with controllers
            $srcDir = Join-Path $root "src"
            New-Item $srcDir -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $srcDir "AuthController.cs") -Value "public class AuthController {}" -Encoding UTF8
            Set-Content (Join-Path $srcDir "PaymentController.cs") -Value "public class PaymentController {}" -Encoding UTF8
        }

        return $root
    }
}

# ═══════════════════════════════════════════════════════════════
# PLAYBOOK DETECTION
# ═══════════════════════════════════════════════════════════════

Describe "Test-PlaybookPresence" {
    It "Detects playbook output (score >= 3)" {
        $repo = New-TestRepo -Full
        $result = Test-PlaybookPresence -RepoPath $repo
        $result.Score | Should -BeGreaterOrEqual 3
        $result.Pass  | Should -Be $true
    }

    It "Rejects repo without playbook (score < 3)" {
        $repo = New-TestRepo -Empty
        $result = Test-PlaybookPresence -RepoPath $repo
        $result.Score | Should -Be 0
        $result.Pass  | Should -Be $false
    }

    It "Detects partial playbook (score 2)" {
        $repo = New-TestRepo -Partial
        $result = Test-PlaybookPresence -RepoPath $repo
        # Partial has copilot-instructions.md (signal 1) + 1 workflow doc (not enough for signal 3)
        $result.Score | Should -BeLessOrEqual 2
        $result.Pass  | Should -Be $false
    }
}

# ═══════════════════════════════════════════════════════════════
# DOCS ROOT DETECTION
# ═══════════════════════════════════════════════════════════════

Describe "Find-DocsRoot" {
    It "Finds DocsRoot from Discovery_Manifest.md" {
        $repo = New-TestRepo -Full
        $result = Find-DocsRoot -RepoPath $repo
        $result | Should -Not -BeNullOrEmpty
        $result | Should -BeLike "*knowledge*"
    }

    It "Returns explicit DocsRoot unchanged" {
        $repo = New-TestRepo -Full
        $explicit = Join-Path $repo "docs" "knowledge"
        $result = Find-DocsRoot -RepoPath $repo -DocsRoot $explicit
        $result | Should -Be $explicit
    }

    It "Returns null for repo with no docs" {
        $repo = New-TestRepo -Empty
        $result = Find-DocsRoot -RepoPath $repo
        $result | Should -BeNullOrEmpty
    }
}

# ═══════════════════════════════════════════════════════════════
# PASS 1: LAYER TAGGING
# ═══════════════════════════════════════════════════════════════

Describe "Invoke-LayerTagging" {
    It "Tags all untagged docs" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo
        $result = Invoke-LayerTagging -DocsRoot $docsRoot -RepoPath $repo
        $result.Tagged | Should -BeGreaterThan 0
        $result.Summary.Total | Should -BeGreaterThan 0
    }

    It "Skips already-tagged docs" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo

        # Pre-tag a doc
        $manifest = Join-Path $docsRoot "Discovery_Manifest.md"
        $content = Get-Content $manifest -Raw
        Set-Content $manifest -Value "<!-- layer: L0 | role: anchor -->`n$content" -NoNewline -Encoding UTF8

        $result = Invoke-LayerTagging -DocsRoot $docsRoot -RepoPath $repo
        $result.Skipped | Should -BeGreaterThan 0
    }

    It "DryRun doesn't write tags" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo

        # Get content before
        $wfDoc = Join-Path $docsRoot "workflows" "01_UserAuth.md"
        $before = Get-Content $wfDoc -Raw

        $result = Invoke-LayerTagging -DocsRoot $docsRoot -RepoPath $repo -DryRun
        $result.Tagged | Should -BeGreaterThan 0

        # Content should be unchanged
        $after = Get-Content $wfDoc -Raw
        $after | Should -Be $before
    }
}

# ═══════════════════════════════════════════════════════════════
# PASS 2: NAVIGATION GUIDE
# ═══════════════════════════════════════════════════════════════

Describe "Invoke-NavigationGuide" {
    It "Injects Navigation Guide into manifest" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo
        $result = Invoke-NavigationGuide -DocsRoot $docsRoot -RepoPath $repo
        $result.Status | Should -Be 'injected'

        $content = Get-Content (Join-Path $docsRoot "Discovery_Manifest.md") -Raw
        $content | Should -Match '## Navigation Guide'
    }

    It "Replaces existing Navigation Guide" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo

        # First inject
        Invoke-NavigationGuide -DocsRoot $docsRoot -RepoPath $repo | Out-Null

        # Second call should replace
        $result = Invoke-NavigationGuide -DocsRoot $docsRoot -RepoPath $repo
        $result.Status | Should -Be 'replaced'
    }

    It "DryRun doesn't modify manifest" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo
        $manifest = Join-Path $docsRoot "Discovery_Manifest.md"
        $before = Get-Content $manifest -Raw

        $result = Invoke-NavigationGuide -DocsRoot $docsRoot -RepoPath $repo -DryRun
        $result.Status | Should -Be 'would-inject'

        $after = Get-Content $manifest -Raw
        $after | Should -Be $before
    }
}

# ═══════════════════════════════════════════════════════════════
# PASS 3: REGISTRY REBUILD
# ═══════════════════════════════════════════════════════════════

Describe "Invoke-RegistryRebuild" {
    It "Rebuilds registry from controllers and docs" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo
        $result = Invoke-RegistryRebuild -RepoPath $repo -DocsRoot $docsRoot
        $result.TotalControllers | Should -BeGreaterThan 0
        $result.DocPath | Should -Not -BeNullOrEmpty

        # Verify file was written
        Test-Path (Join-Path $docsRoot "doc_registry.md") | Should -Be $true
    }

    It "DryRun does not write registry file" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo

        # Remove existing registry
        $regPath = Join-Path $docsRoot "doc_registry.md"
        Remove-Item $regPath -Force

        $result = Invoke-RegistryRebuild -RepoPath $repo -DocsRoot $docsRoot -DryRun
        $result.DryRun | Should -Be $true

        # File should not have been recreated
        Test-Path $regPath | Should -Be $false
    }
}

# ═══════════════════════════════════════════════════════════════
# PASS 4: CODE POINTER AUDIT
# ═══════════════════════════════════════════════════════════════

Describe "Invoke-CodePointerAudit" {
    It "Reports dead refs" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo

        # Add a doc with a dead reference
        $wfDoc = Join-Path $docsRoot "workflows" "01_UserAuth.md"
        $content = @"
# User Auth Workflow
## 1. Overview
Some content
## 6. Key Source Files
| ``src/NonExistent/FakeFile.cs`` | Controller | Main entry |
"@
        Set-Content $wfDoc -Value $content -Encoding UTF8

        $result = Invoke-CodePointerAudit -DocsRoot $docsRoot -RepoPath $repo
        $result.DeadRefs | Should -BeGreaterThan 0
    }

    It "Passes when all refs resolve" {
        # Build a minimal repo with no code refs at all
        $repo = Join-Path $TestDrive "clean-repo-$(Get-Random)"
        $docsDir = Join-Path $repo "docs"
        $wfDir = Join-Path $docsDir "workflows"
        New-Item $wfDir -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $wfDir "01_Simple.md") -Value "# Simple`nJust plain text, no file references." -Encoding UTF8

        $result = Invoke-CodePointerAudit -DocsRoot $docsDir -RepoPath $repo
        $result.Pass | Should -Be $true
        $result.DeadRefs | Should -Be 0
    }
}

# ═══════════════════════════════════════════════════════════════
# PASS 5: DOC SIZE CHECK
# ═══════════════════════════════════════════════════════════════

Describe "Invoke-DocSizeCheck" {
    It "Flags oversize docs" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo

        # Create a 700-line workflow doc
        $wfDoc = Join-Path $docsRoot "workflows" "01_UserAuth.md"
        $lines = @("# User Auth Workflow")
        1..700 | ForEach-Object { $lines += "Line $_ of content" }
        $bigContent = $lines -join "`n"
        Set-Content $wfDoc -Value $bigContent -Encoding UTF8

        $result = Invoke-DocSizeCheck -DocsRoot $docsRoot -RepoPath $repo
        $result.Flagged | Should -BeGreaterThan 0
        $result.FlaggedNames | Should -Contain "01_UserAuth.md"
    }

    It "All docs under limit returns zero flagged" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo

        # All test docs are small
        $result = Invoke-DocSizeCheck -DocsRoot $docsRoot -RepoPath $repo
        $result.Flagged | Should -Be 0
        $result.UnderLimit | Should -Be $result.Total
    }

    It "AutoFix produces recommendations for oversize docs" {
        $repo = New-TestRepo -Full
        $docsRoot = Find-DocsRoot -RepoPath $repo

        $wfDoc = Join-Path $docsRoot "workflows" "01_UserAuth.md"
        $lines = @("# User Auth Workflow")
        1..700 | ForEach-Object { $lines += "Line $_ of content" }
        $bigContent = $lines -join "`n"
        Set-Content $wfDoc -Value $bigContent -Encoding UTF8

        $result = Invoke-DocSizeCheck -DocsRoot $docsRoot -RepoPath $repo -AutoFix
        $result.Recommendations.Count | Should -BeGreaterThan 0
    }
}

# ═══════════════════════════════════════════════════════════════
# REPORT GENERATION
# ═══════════════════════════════════════════════════════════════

Describe "Build-RetrofitReport" {
    It "Generates complete report with all sections" {
        $layerResult = @{
            Tagged = 5; Skipped = 2
            Summary = @{ L0 = 1; L1 = 2; L2 = 1; L3 = 3; Total = 7; Tagged = 2; Untagged = 5 }
        }
        $navResult = @{ Status = 'injected'; ManifestPath = 'Discovery_Manifest.md' }
        $registryResult = @{ TotalControllers = 4; CoveragePct = 75; DryRun = $false }
        $pointerResult = @{ TotalRefs = 20; DeadRefs = 2; DeadPct = 10; Pass = $true; AutoFixed = 0 }
        $sizingResult = @{ Total = 7; UnderLimit = 6; Flagged = 1; FlaggedNames = @('big.md') }

        $report = Build-RetrofitReport `
            -LayerResult $layerResult `
            -NavResult $navResult `
            -RegistryResult $registryResult `
            -PointerResult $pointerResult `
            -SizingResult $sizingResult

        $report.Lines | Should -Not -BeNullOrEmpty
        ($report.Lines -join "`n") | Should -Match 'Retrofit Report'
        ($report.Lines -join "`n") | Should -Match 'Layer tags added'
        ($report.Lines -join "`n") | Should -Match 'Navigation Guide'
        ($report.Lines -join "`n") | Should -Match 'Registry rebuilt'
        ($report.Lines -join "`n") | Should -Match 'Code pointers'
        ($report.Lines -join "`n") | Should -Match 'Doc sizing'
    }

    It "Reports issues when pointer audit fails" {
        $pointerResult = @{ TotalRefs = 10; DeadRefs = 5; DeadPct = 50; Pass = $false; AutoFixed = 0 }
        $report = Build-RetrofitReport -PointerResult $pointerResult
        $report.HasIssues | Should -Be $true
        ($report.Lines -join "`n") | Should -Match 'FAIL'
    }

    It "Reports clean when all passes succeed" {
        $layerResult = @{
            Tagged = 3; Skipped = 0
            Summary = @{ L0 = 1; L1 = 1; L2 = 0; L3 = 1; Total = 3; Tagged = 0; Untagged = 3 }
        }
        $navResult = @{ Status = 'injected'; ManifestPath = 'x.md' }
        $registryResult = @{ TotalControllers = 2; CoveragePct = 100; DryRun = $false }
        $pointerResult = @{ TotalRefs = 5; DeadRefs = 0; DeadPct = 0; Pass = $true; AutoFixed = 0 }
        $sizingResult = @{ Total = 3; UnderLimit = 3; Flagged = 0; FlaggedNames = @() }

        $report = Build-RetrofitReport `
            -LayerResult $layerResult `
            -NavResult $navResult `
            -RegistryResult $registryResult `
            -PointerResult $pointerResult `
            -SizingResult $sizingResult

        $report.HasIssues | Should -Be $false
        $report.OverallStatus | Should -Match 'Retrofit complete'
    }
}
