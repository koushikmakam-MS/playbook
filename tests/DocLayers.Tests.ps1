<#
.SYNOPSIS
    Pester tests for DocLayers.psm1 — Layer classification, tagging, and navigation
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\shared\DocLayers.psm1" -Force
}

Describe "Get-DocLayer" {
    # ── L0 classification ──
    It "Classifies Discovery_Manifest.md as L0 anchor" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\Discovery_Manifest.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L0'
        $r.Role  | Should -Be 'anchor'
    }

    It "Classifies doc_registry.md as L0 index" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\doc_registry.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L0'
        $r.Role  | Should -Be 'index'
    }

    It "Classifies copilot-instructions.md as L0 agent-config" {
        $r = Get-DocLayer -FilePath "C:\repo\.github\copilot-instructions.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L0'
        $r.Role  | Should -Be 'agent-config'
    }

    # ── L1 classification ──
    It "Classifies Architecture_Memory.md as L1 architecture" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\Architecture_Memory.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L1'
        $r.Role  | Should -Be 'architecture'
    }

    It "Classifies Glossary.md as L1 glossary" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\Glossary.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L1'
        $r.Role  | Should -Be 'glossary'
    }

    It "Classifies copilot-memory.md as L1 architecture" {
        $r = Get-DocLayer -FilePath "C:\repo\.github\copilot-memory.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L1'
        $r.Role  | Should -Be 'architecture'
    }

    # ── L2 classification ──
    It "Classifies ErrorCode_Reference.md as L2 error-catalog" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\ErrorCode_Reference.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L2'
        $r.Role  | Should -Be 'error-catalog'
    }

    It "Classifies Telemetry_And_Logging.md as L2 telemetry" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\Telemetry_And_Logging.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L2'
        $r.Role  | Should -Be 'telemetry'
    }

    It "Classifies adr/ADR-0001.md as L2 decision-record" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\adr\ADR-0001.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L2'
        $r.Role  | Should -Be 'decision-record'
    }

    It "Classifies skills/coding/SKILL.md as L2 skill" {
        $r = Get-DocLayer -FilePath "C:\repo\.github\skills\coding\SKILL.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L2'
        $r.Role  | Should -Be 'skill'
    }

    # ── L3 classification ──
    It "Classifies workflows/01_Auth.md as L3 workflow" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\workflows\01_Auth.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L3'
        $r.Role  | Should -Be 'workflow'
    }

    It "Classifies workflows/05_Backup_Restore.md as L3 workflow" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\workflows\05_Backup_Restore.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L3'
        $r.Role  | Should -Be 'workflow'
    }

    # ── Default ──
    It "Classifies unknown doc as L1 general" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\RandomNotes.md" -RepoPath "C:\repo"
        $r.Layer | Should -Be 'L1'
        $r.Role  | Should -Be 'general'
    }

    # ── RelPath ──
    It "Computes relative path correctly" {
        $r = Get-DocLayer -FilePath "C:\repo\docs\agentKT\workflows\01_Auth.md" -RepoPath "C:\repo"
        $r.RelPath | Should -Match 'docs.*agentKT.*workflows.*01_Auth\.md'
    }
}

Describe "Get-DocLayerTag" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-doclayers-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Reads full layer tag with role and read-order" {
        $file = Join-Path $script:testDir "test.md"
        "<!-- layer: L0 | role: anchor | read-order: 1 -->`n# Title" | Set-Content $file -Encoding UTF8
        $tag = Get-DocLayerTag -FilePath $file
        $tag.Layer     | Should -Be 'L0'
        $tag.Role      | Should -Be 'anchor'
        $tag.ReadOrder | Should -Be 1
    }

    It "Reads tag with layer only" {
        $file = Join-Path $script:testDir "test.md"
        "<!-- layer: L2 -->`n# Title" | Set-Content $file -Encoding UTF8
        $tag = Get-DocLayerTag -FilePath $file
        $tag.Layer | Should -Be 'L2'
        $tag.Role  | Should -BeNullOrEmpty
    }

    It "Returns null for file without tag" {
        $file = Join-Path $script:testDir "test.md"
        "# Title`nSome content" | Set-Content $file -Encoding UTF8
        $tag = Get-DocLayerTag -FilePath $file
        $tag | Should -BeNullOrEmpty
    }

    It "Returns null for non-existent file" {
        $tag = Get-DocLayerTag -FilePath (Join-Path $script:testDir "nope.md")
        $tag | Should -BeNullOrEmpty
    }

    It "Reads tag not on first line" {
        $file = Join-Path $script:testDir "test.md"
        "`n`n<!-- layer: L3 | role: workflow -->`n# Title" | Set-Content $file -Encoding UTF8
        $tag = Get-DocLayerTag -FilePath $file
        $tag.Layer | Should -Be 'L3'
        $tag.Role  | Should -Be 'workflow'
    }
}

Describe "Set-DocLayerTag" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-doclayers-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Adds tag to file without existing tag" {
        $file = Join-Path $script:testDir "test.md"
        "# Title`nContent" | Set-Content $file -Encoding UTF8
        $result = Set-DocLayerTag -FilePath $file -Layer 'L1' -Role 'architecture'
        $result | Should -Be $true
        $content = Get-Content $file -Raw
        $content | Should -Match '<!-- layer: L1 \| role: architecture -->'
        $content | Should -Match '# Title'
    }

    It "Replaces existing tag" {
        $file = Join-Path $script:testDir "test.md"
        "<!-- layer: L0 | role: old -->`n# Title" | Set-Content $file -Encoding UTF8
        Set-DocLayerTag -FilePath $file -Layer 'L2' -Role 'new-role'
        $content = Get-Content $file -Raw
        $content | Should -Match '<!-- layer: L2 \| role: new-role -->'
        $content | Should -Not -Match 'L0'
    }

    It "Includes read-order when specified" {
        $file = Join-Path $script:testDir "test.md"
        "# Title" | Set-Content $file -Encoding UTF8
        Set-DocLayerTag -FilePath $file -Layer 'L0' -Role 'anchor' -ReadOrder 1
        $content = Get-Content $file -Raw
        $content | Should -Match 'read-order: 1'
    }

    It "Returns false for non-existent file" {
        $result = Set-DocLayerTag -FilePath (Join-Path $script:testDir "nope.md") -Layer 'L0'
        $result | Should -Be $false
    }

    It "Round-trips: Set then Get returns same values" {
        $file = Join-Path $script:testDir "test.md"
        "# Title" | Set-Content $file -Encoding UTF8
        Set-DocLayerTag -FilePath $file -Layer 'L3' -Role 'workflow' -ReadOrder 5
        $tag = Get-DocLayerTag -FilePath $file
        $tag.Layer     | Should -Be 'L3'
        $tag.Role      | Should -Be 'workflow'
        $tag.ReadOrder | Should -Be 5
    }
}

Describe "Get-AllDocLayers" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-doclayers-$(Get-Random)"
        $script:docsRoot = Join-Path $script:testDir "docs\agentKT"
        $script:wfDir = Join-Path $script:docsRoot "workflows"
        $script:adrDir = Join-Path $script:docsRoot "adr"
        New-Item -ItemType Directory $script:wfDir -Force | Out-Null
        New-Item -ItemType Directory $script:adrDir -Force | Out-Null

        "# Discovery" | Set-Content (Join-Path $script:docsRoot "Discovery_Manifest.md") -Encoding UTF8
        "# Arch"      | Set-Content (Join-Path $script:docsRoot "Architecture_Memory.md") -Encoding UTF8
        "# Auth WF"   | Set-Content (Join-Path $script:wfDir "01_Auth.md") -Encoding UTF8
        "# Backup WF" | Set-Content (Join-Path $script:wfDir "05_Backup.md") -Encoding UTF8
        "# ADR-001"   | Set-Content (Join-Path $script:adrDir "ADR-0001.md") -Encoding UTF8
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns all docs classified by layer" {
        $results = Get-AllDocLayers -DocsRoot $script:docsRoot -RepoPath $script:testDir
        $results.Count | Should -Be 5
    }

    It "Correctly classifies L0 docs" {
        $results = Get-AllDocLayers -DocsRoot $script:docsRoot -RepoPath $script:testDir
        $l0 = @($results | Where-Object { $_.Layer -eq 'L0' })
        $l0.Count | Should -Be 1
        $l0[0].Role | Should -Be 'anchor'
    }

    It "Correctly classifies L3 workflow docs" {
        $results = Get-AllDocLayers -DocsRoot $script:docsRoot -RepoPath $script:testDir
        $l3 = @($results | Where-Object { $_.Layer -eq 'L3' })
        $l3.Count | Should -Be 2
    }

    It "Correctly classifies L2 ADR docs" {
        $results = Get-AllDocLayers -DocsRoot $script:docsRoot -RepoPath $script:testDir
        $l2 = @($results | Where-Object { $_.Layer -eq 'L2' })
        $l2.Count | Should -Be 1
        $l2[0].Role | Should -Be 'decision-record'
    }

    It "Reports tagged status correctly" {
        # Tag one file
        $manifest = Join-Path $script:docsRoot "Discovery_Manifest.md"
        "<!-- layer: L0 | role: anchor -->`n# Discovery" | Set-Content $manifest -Encoding UTF8

        $results = Get-AllDocLayers -DocsRoot $script:docsRoot -RepoPath $script:testDir
        $tagged = @($results | Where-Object { $_.Tagged })
        $untagged = @($results | Where-Object { -not $_.Tagged })
        $tagged.Count   | Should -Be 1
        $untagged.Count | Should -Be 4
    }

    It "Returns empty for non-existent directory" {
        $results = Get-AllDocLayers -DocsRoot (Join-Path $script:testDir "nonexistent") -RepoPath $script:testDir
        $results | Should -HaveCount 0
    }
}

Describe "Get-LayerSummary" {
    It "Summarizes layer counts correctly" {
        $docs = @(
            [PSCustomObject]@{ Layer = 'L0'; Tagged = $true }
            [PSCustomObject]@{ Layer = 'L1'; Tagged = $false }
            [PSCustomObject]@{ Layer = 'L1'; Tagged = $true }
            [PSCustomObject]@{ Layer = 'L2'; Tagged = $false }
            [PSCustomObject]@{ Layer = 'L3'; Tagged = $false }
            [PSCustomObject]@{ Layer = 'L3'; Tagged = $false }
        )
        $s = Get-LayerSummary -DocLayers $docs
        $s.L0      | Should -Be 1
        $s.L1      | Should -Be 2
        $s.L2      | Should -Be 1
        $s.L3      | Should -Be 2
        $s.Total   | Should -Be 6
        $s.Tagged  | Should -Be 2
        $s.Untagged | Should -Be 4
    }

    It "Handles empty array" {
        $s = Get-LayerSummary -DocLayers @()
        $s.Total | Should -Be 0
        $s.L0    | Should -Be 0
    }
}

Describe "Build-NavigationGuide" {
    It "Generates markdown with Navigation Guide header" {
        $docs = @(
            [PSCustomObject]@{ Layer = 'L0'; Role = 'anchor'; RelPath = 'docs/Discovery_Manifest.md'; FilePath = 'x' }
            [PSCustomObject]@{ Layer = 'L1'; Role = 'architecture'; RelPath = 'docs/Architecture_Memory.md'; FilePath = 'x' }
            [PSCustomObject]@{ Layer = 'L3'; Role = 'workflow'; RelPath = 'docs/workflows/01_Auth.md'; FilePath = 'x' }
        )
        $guide = Build-NavigationGuide -DocLayers $docs
        $guide | Should -Match '## Navigation Guide'
        $guide | Should -Match 'L0.*L1.*L2.*L3'
    }

    It "Includes architecture doc link" {
        $docs = @(
            [PSCustomObject]@{ Layer = 'L0'; Role = 'anchor'; RelPath = 'docs/Discovery_Manifest.md'; FilePath = 'x' }
            [PSCustomObject]@{ Layer = 'L1'; Role = 'architecture'; RelPath = 'docs/Architecture_Memory.md'; FilePath = 'x' }
        )
        $guide = Build-NavigationGuide -DocLayers $docs
        $guide | Should -Match 'Architecture_Memory\.md'
    }

    It "Includes workflow doc links (up to 5)" {
        $docs = @(
            [PSCustomObject]@{ Layer = 'L0'; Role = 'anchor'; RelPath = 'docs/Discovery_Manifest.md'; FilePath = 'x' }
        )
        for ($i = 1; $i -le 7; $i++) {
            $docs += [PSCustomObject]@{ Layer = 'L3'; Role = 'workflow'; RelPath = "docs/workflows/0${i}_Feature.md"; FilePath = 'x' }
        }
        $guide = Build-NavigationGuide -DocLayers $docs
        # Should include at most 5 workflow rows
        $wfRows = ($guide -split "`n" | Where-Object { $_ -match 'workflows/0\d_Feature' })
        $wfRows.Count | Should -BeLessOrEqual 5
    }

    It "Handles empty doc list gracefully" {
        $guide = Build-NavigationGuide -DocLayers @()
        $guide | Should -Match '## Navigation Guide'
    }
}

Describe "Get-LayerDefinitions" {
    It "Returns all 4 layers" {
        $defs = Get-LayerDefinitions
        $defs.Keys | Should -Contain 'L0'
        $defs.Keys | Should -Contain 'L1'
        $defs.Keys | Should -Contain 'L2'
        $defs.Keys | Should -Contain 'L3'
    }

    It "Each layer has Label, Purpose, Description" {
        $defs = Get-LayerDefinitions
        foreach ($key in $defs.Keys) {
            $defs[$key].Label       | Should -Not -BeNullOrEmpty
            $defs[$key].Purpose     | Should -Not -BeNullOrEmpty
            $defs[$key].Description | Should -Not -BeNullOrEmpty
        }
    }
}
