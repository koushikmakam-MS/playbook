<#
.SYNOPSIS
    Pester tests for DocRegistry.psm1 — Deterministic doc_registry builder
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\shared\DocRegistry.psm1" -Force
}

# ═══════════════════════════════════════════════════════════════
# Get-ControllerList
# ═══════════════════════════════════════════════════════════════

Describe "Get-ControllerList" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-docregistry-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Finds .cs controllers in test dir" {
        $srcDir = Join-Path $script:testDir "src\Controllers"
        New-Item -ItemType Directory $srcDir -Force | Out-Null
        "" | Set-Content (Join-Path $srcDir "UserController.cs")
        "" | Set-Content (Join-Path $srcDir "OrderController.cs")

        $result = Get-ControllerList -RepoPath $script:testDir
        $result.Count | Should -Be 2
        $names = $result | ForEach-Object { $_.Name }
        $names | Should -Contain 'UserController'
        $names | Should -Contain 'OrderController'
    }

    It "Finds .py handlers" {
        $srcDir = Join-Path $script:testDir "app\handlers"
        New-Item -ItemType Directory $srcDir -Force | Out-Null
        "" | Set-Content (Join-Path $srcDir "auth_handler.py")
        "" | Set-Content (Join-Path $srcDir "PaymentHandler.cs")

        $result = Get-ControllerList -RepoPath $script:testDir
        $result.Count | Should -Be 2
        $names = $result | ForEach-Object { $_.Name }
        $names | Should -Contain 'auth_handler'
        $names | Should -Contain 'PaymentHandler'
    }

    It "Returns empty for dir with no controllers" {
        $srcDir = Join-Path $script:testDir "src"
        New-Item -ItemType Directory $srcDir -Force | Out-Null
        "" | Set-Content (Join-Path $srcDir "README.md")
        "" | Set-Content (Join-Path $srcDir "utils.cs")

        $result = @(Get-ControllerList -RepoPath $script:testDir)
        $result.Count | Should -Be 0
    }

    It "Excludes node_modules, bin, obj directories" {
        $nmDir = Join-Path $script:testDir "node_modules\some-pkg"
        $binDir = Join-Path $script:testDir "bin\Debug"
        $objDir = Join-Path $script:testDir "obj\Release"
        $srcDir = Join-Path $script:testDir "src"
        New-Item -ItemType Directory $nmDir -Force | Out-Null
        New-Item -ItemType Directory $binDir -Force | Out-Null
        New-Item -ItemType Directory $objDir -Force | Out-Null
        New-Item -ItemType Directory $srcDir -Force | Out-Null

        "" | Set-Content (Join-Path $nmDir "FakeController.cs")
        "" | Set-Content (Join-Path $binDir "AppController.cs")
        "" | Set-Content (Join-Path $objDir "ObjController.cs")
        "" | Set-Content (Join-Path $srcDir "RealController.cs")

        $result = @(Get-ControllerList -RepoPath $script:testDir)
        $result.Count | Should -Be 1
        $result[0].Name | Should -Be 'RealController'
    }
}

# ═══════════════════════════════════════════════════════════════
# Get-WorkflowDocs
# ═══════════════════════════════════════════════════════════════

Describe "Get-WorkflowDocs" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-docregistry-$(Get-Random)"
        $script:docsRoot = Join-Path $script:testDir "docs\agentKT"
        $script:wfDir = Join-Path $script:docsRoot "workflows"
        New-Item -ItemType Directory $script:wfDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Counts sections correctly for complete doc (11/11)" {
        $content = @'
# Auth Workflow
## 1. Overview
Some overview text
## 2. Trigger Points
Triggers here
## 3. API Endpoints
Endpoints here
## 4. Request/Response
Request details
## 5. Sequence Diagram
```mermaid
sequenceDiagram
    A->>B: call
```
## 6. Key Source Files
Files here
## 7. Configuration
Config here
## 8. Telemetry
Telemetry here
## 9. How to Debug
Debug info
## 10. Error Scenarios
Errors here
'@
        Set-Content (Join-Path $script:wfDir "01_Auth.md") -Value $content -Encoding UTF8

        $result = @(Get-WorkflowDocs -DocsRoot $script:docsRoot)
        $result.Count | Should -Be 1
        $doc = $result[0]
        $doc.SectionsPresent.Count | Should -Be 11
        $doc.MissingSections.Count | Should -Be 0
    }

    It "Counts sections correctly for partial doc (5/11)" {
        $content = @"
# Payment Workflow
## 1. Overview
Some overview
## 3. API Endpoints
Endpoints
## 6. Key Source Files
Files
## 7. Configuration
Config
## 9. How to Debug
Debug
"@
        Set-Content (Join-Path $script:wfDir "02_Payment.md") -Value $content -Encoding UTF8

        $result = @(Get-WorkflowDocs -DocsRoot $script:docsRoot)
        $result.Count | Should -Be 1
        $doc = $result[0]
        $doc.SectionsPresent.Count | Should -Be 5
        $doc.MissingSections.Count | Should -Be 6
        $doc.SectionsTotal | Should -Be 11
    }

    It "Detects missing mermaid block" {
        $content = @"
# Workflow
## 5. Sequence Diagram
No mermaid here, just text
"@
        Set-Content (Join-Path $script:wfDir "03_NoMermaid.md") -Value $content -Encoding UTF8

        $result = @(Get-WorkflowDocs -DocsRoot $script:docsRoot)
        $doc = $result[0]
        $doc.MissingSections | Should -Contain '```mermaid'
    }

    It "Returns empty for no workflow docs" {
        $emptyDocsRoot = Join-Path $script:testDir "emptydocs"
        New-Item -ItemType Directory $emptyDocsRoot -Force | Out-Null

        $result = @(Get-WorkflowDocs -DocsRoot $emptyDocsRoot)
        $result.Count | Should -Be 0
    }

    It "Extracts controller references from doc content" {
        $content = @"
# Auth Workflow
## 1. Overview
This workflow uses the AuthController and UserController classes.
Also references PaymentHandler for billing.
"@
        Set-Content (Join-Path $script:wfDir "01_Auth.md") -Value $content -Encoding UTF8

        $result = @(Get-WorkflowDocs -DocsRoot $script:docsRoot)
        $doc = $result[0]
        $doc.ControllersReferenced | Should -Contain 'AuthController'
        $doc.ControllersReferenced | Should -Contain 'UserController'
    }
}

# ═══════════════════════════════════════════════════════════════
# Build-DocRegistry
# ═══════════════════════════════════════════════════════════════

Describe "Build-DocRegistry" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-docregistry-$(Get-Random)"
        $script:srcDir = Join-Path $script:testDir "src\Controllers"
        $script:docsRoot = Join-Path $script:testDir "docs\agentKT"
        $script:wfDir = Join-Path $script:docsRoot "workflows"
        New-Item -ItemType Directory $script:srcDir -Force | Out-Null
        New-Item -ItemType Directory $script:wfDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Builds registry with documented controllers" {
        "" | Set-Content (Join-Path $script:srcDir "AuthController.cs")
        $wfContent = @"
# Auth Workflow
## 1. Overview
Uses AuthController for authentication.
"@
        Set-Content (Join-Path $script:wfDir "01_Auth.md") -Value $wfContent -Encoding UTF8

        $result = Build-DocRegistry -RepoPath $script:testDir -DocsRoot $script:docsRoot
        $result.Documented | Should -Be 1
        $result.TotalControllers | Should -Be 1
        $result.CoveragePct | Should -Be 100
    }

    It "Marks undocumented controllers correctly" {
        "" | Set-Content (Join-Path $script:srcDir "AuthController.cs")
        "" | Set-Content (Join-Path $script:srcDir "OrphanController.cs")
        $wfContent = @"
# Auth Workflow
## 1. Overview
Uses AuthController for authentication.
"@
        Set-Content (Join-Path $script:wfDir "01_Auth.md") -Value $wfContent -Encoding UTF8

        $result = Build-DocRegistry -RepoPath $script:testDir -DocsRoot $script:docsRoot
        $result.Documented | Should -Be 1
        $result.Undocumented | Should -Be 1
        $result.CoveragePct | Should -Be 50

        $registryContent = Get-Content (Join-Path $script:docsRoot "doc_registry.md") -Raw
        $registryContent | Should -Match 'OrphanController'
        $registryContent | Should -Match 'Undocumented Controllers'
    }

    It "Includes per-layer coverage summary" {
        "" | Set-Content (Join-Path $script:srcDir "AuthController.cs")
        "# Auth" | Set-Content (Join-Path $script:wfDir "01_Auth.md") -Encoding UTF8

        $result = Build-DocRegistry -RepoPath $script:testDir -DocsRoot $script:docsRoot
        $result.LayerSummary | Should -Not -BeNullOrEmpty
        $result.LayerSummary.Keys | Should -Contain 'L0'
        $result.LayerSummary.Keys | Should -Contain 'L3'

        $registryContent = Get-Content (Join-Path $script:docsRoot "doc_registry.md") -Raw
        $registryContent | Should -Match 'Layer Breakdown'
    }

    It "Creates registry file atomically (no .tmp left behind)" {
        "" | Set-Content (Join-Path $script:srcDir "AuthController.cs")
        "# Auth" | Set-Content (Join-Path $script:wfDir "01_Auth.md") -Encoding UTF8

        Build-DocRegistry -RepoPath $script:testDir -DocsRoot $script:docsRoot | Out-Null

        $registryPath = Join-Path $script:docsRoot "doc_registry.md"
        $tmpPath = "$registryPath.tmp"
        Test-Path $registryPath | Should -Be $true
        Test-Path $tmpPath | Should -Be $false
    }

    It "Merges change log entries when present" {
        "" | Set-Content (Join-Path $script:srcDir "AuthController.cs")
        "# Auth" | Set-Content (Join-Path $script:wfDir "01_Auth.md") -Encoding UTF8

        $changeLogPath = Join-Path $script:testDir ".doc-changes.log"
        "ADD|workflows/01_Auth.md||Added auth workflow|2026-04-29" | Set-Content $changeLogPath -Encoding UTF8

        Build-DocRegistry -RepoPath $script:testDir -DocsRoot $script:docsRoot -ChangeLogPath $changeLogPath | Out-Null

        $registryContent = Get-Content (Join-Path $script:docsRoot "doc_registry.md") -Raw
        $registryContent | Should -Match 'Recent Changes'
        $registryContent | Should -Match 'Added auth workflow'
    }

    It "Handles empty repo gracefully" {
        $emptyRepo = Join-Path $script:testDir "empty"
        $emptyDocs = Join-Path $emptyRepo "docs"
        New-Item -ItemType Directory $emptyDocs -Force | Out-Null

        $result = Build-DocRegistry -RepoPath $emptyRepo -DocsRoot $emptyDocs
        $result.TotalControllers | Should -Be 0
        $result.Documented | Should -Be 0
        $result.CoveragePct | Should -Be 0
    }
}

# ═══════════════════════════════════════════════════════════════
# Add-ChangeLogEntry
# ═══════════════════════════════════════════════════════════════

Describe "Add-ChangeLogEntry" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-docregistry-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
        $script:logPath = Join-Path $script:testDir ".doc-changes.log"
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Creates new log file if missing" {
        Test-Path $script:logPath | Should -Be $false
        Add-ChangeLogEntry -ChangeLogPath $script:logPath -Action 'ADD' -DocPath 'workflows/01_Auth.md' -Details 'New workflow'
        Test-Path $script:logPath | Should -Be $true

        $content = Get-Content $script:logPath
        $content | Should -Match 'ADD'
        $content | Should -Match 'workflows/01_Auth.md'
    }

    It "Appends to existing log" {
        Add-ChangeLogEntry -ChangeLogPath $script:logPath -Action 'ADD' -DocPath 'doc1.md' -Details 'First'
        Add-ChangeLogEntry -ChangeLogPath $script:logPath -Action 'UPDATE' -DocPath 'doc2.md' -Details 'Second'

        $lines = @(Get-Content $script:logPath)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match 'ADD'
        $lines[1] | Should -Match 'UPDATE'
    }

    It "Includes parent doc reference when provided" {
        Add-ChangeLogEntry -ChangeLogPath $script:logPath -Action 'ADD' -DocPath 'sub.md' -Details 'Child doc' -ParentDoc 'parent.md'

        $content = Get-Content $script:logPath -Raw
        $content | Should -Match 'PARENT:parent.md'
    }
}

# ═══════════════════════════════════════════════════════════════
# Read-ChangeLog
# ═══════════════════════════════════════════════════════════════

Describe "Read-ChangeLog" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-docregistry-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
        $script:logPath = Join-Path $script:testDir ".doc-changes.log"
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Parses all fields correctly" {
        @(
            "ADD|workflows/01_Auth.md|PARENT:manifest.md|New auth doc|2026-04-29"
            "UPDATE|workflows/02_Pay.md||Updated payment|2026-04-30"
        ) | Set-Content $script:logPath -Encoding UTF8

        $result = Read-ChangeLog -ChangeLogPath $script:logPath
        $result.Count | Should -Be 2

        $result[0].Action  | Should -Be 'ADD'
        $result[0].DocPath | Should -Be 'workflows/01_Auth.md'
        $result[0].Parent  | Should -Be 'manifest.md'
        $result[0].Details | Should -Be 'New auth doc'
        $result[0].Date    | Should -Be '2026-04-29'

        $result[1].Action  | Should -Be 'UPDATE'
        $result[1].Parent  | Should -BeNullOrEmpty
    }

    It "Returns empty for missing file" {
        $result = @(Read-ChangeLog -ChangeLogPath (Join-Path $script:testDir "nonexistent.log"))
        $result.Count | Should -Be 0
    }

    It "Handles malformed lines gracefully" {
        @(
            "ADD|workflows/01_Auth.md|PARENT:x|details|2026-04-29"
            "BAD"
            ""
            "UPDATE|doc.md||info|2026-05-01"
        ) | Set-Content $script:logPath -Encoding UTF8

        $result = Read-ChangeLog -ChangeLogPath $script:logPath
        $result.Count | Should -Be 2
    }
}

# ═══════════════════════════════════════════════════════════════
# Clear-ChangeLog
# ═══════════════════════════════════════════════════════════════

Describe "Clear-ChangeLog" {
    BeforeEach {
        $script:testDir = Join-Path $env:TEMP "pester-docregistry-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
        $script:logPath = Join-Path $script:testDir ".doc-changes.log"
    }
    AfterEach {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Removes file content" {
        "ADD|doc.md||test|2026-04-29" | Set-Content $script:logPath -Encoding UTF8
        Test-Path $script:logPath | Should -Be $true

        Clear-ChangeLog -ChangeLogPath $script:logPath
        Test-Path $script:logPath | Should -Be $false
    }

    It "Handles missing file gracefully" {
        { Clear-ChangeLog -ChangeLogPath (Join-Path $script:testDir "nonexistent.log") } | Should -Not -Throw
    }
}
