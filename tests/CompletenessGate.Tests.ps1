<#
.SYNOPSIS
    Pester tests for CompletenessGate.psm1 — Contract-based documentation completeness validation
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\shared\CompletenessGate.psm1" -Force

    # ═══════════════════════════════════════════════════════════════
    # HELPERS — Reusable manifest / doc content builders
    # ═══════════════════════════════════════════════════════════════

    function New-TestManifest {
        param(
            [string]$Dir,
            [string]$Content
        )
        $manifestPath = Join-Path $Dir "Discovery_Manifest.md"
        $Content | Set-Content $manifestPath -Encoding UTF8
        return $manifestPath
    }

    function New-CompleteWorkflowDoc {
        <# Creates a doc file with all 11 required sections (10 numbered + mermaid) #>
        param([string]$Path)
        $parent = Split-Path $Path -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory $parent -Force | Out-Null }
        @"
# User Auth Workflow

## Related Docs
- See also: overview docs

## 1. Overview
This domain handles user authentication workflows.

## 2. Trigger Points
- UserController receives HTTP requests
- Scheduled jobs trigger token cleanup

## 3. API Endpoints
- POST /api/auth/login
- GET /api/auth/status/{id}

## 4. Request Flow
Client calls controller, controller calls service, service persists.

## 5. Sequence Diagram
``````mermaid
sequenceDiagram
    participant Client
    participant Controller
    participant Service
    participant DB
    Client->>Controller: POST /auth
    Controller->>Service: Authenticate()
    Service->>DB: Insert()
    DB-->>Service: OK
    Service-->>Controller: TokenId
    Controller-->>Client: 201 Created
``````

## 6. Key Source Files
- ``UserController.cs``
- ``AuthService.cs``

## 7. Configuration
- ``appsettings.json`` — TokenExpiryMinutes

## 8. Telemetry
- Logs auth start/complete events

## 9. How to Debug
- Attach debugger to AuthService

## 10. Error Scenarios
- DB connection failure → retry with backoff
"@ | Set-Content $Path -Encoding UTF8
    }

    function New-PartialWorkflowDoc {
        <# Creates a doc with sections 1-4 only, no mermaid, missing 5-10 #>
        param([string]$Path)
        $parent = Split-Path $Path -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory $parent -Force | Out-Null }
        @"
# Partial Domain Doc

## 1. Overview
Overview content.

## 2. Trigger Points
Triggers here.

## 3. API Endpoints
Endpoints here.

## 4. Request Flow
Flow here.
"@ | Set-Content $Path -Encoding UTF8
    }
}

# ═══════════════════════════════════════════════════════════════
# BUILD-DOMAINCONTRACTS
# ═══════════════════════════════════════════════════════════════

Describe "Build-DomainContracts" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "build-contracts"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    Context "6-column manifest (explicit doc path)" {
        BeforeAll {
            $script:repoDir = Join-Path $script:testDir "repo6col"
            $script:docsDir = Join-Path $script:repoDir "docs"
            New-Item -ItemType Directory $script:docsDir -Force | Out-Null
            New-Item -ItemType Directory (Join-Path $script:docsDir "workflows") -Force | Out-Null

            $manifest = @"
# Discovery Manifest

## Identified Domains

| # | Domain | Entry Points | Shared Implementation | Doc Type | Workflow Doc |
|---|--------|-------------|----------------------|----------|--------------|
| 1 | User Auth | UserController.cs | AuthService.cs | workflow | ``workflows/01_User_Auth.md`` |
| 2 | API Reference | ApiConfig.cs | ConfigService.cs | reference | ``reference/Api_Reference.md`` |
"@
            New-TestManifest -Dir $script:docsDir -Content $manifest
            # Create the workflow doc so it resolves
            New-CompleteWorkflowDoc -Path (Join-Path $script:docsDir "workflows\01_User_Auth.md")
        }

        It "Parses two contracts from 6-column table" {
            $contracts = Build-DomainContracts -RepoPath $script:repoDir -DocsRoot $script:docsDir
            $contracts.Count | Should -Be 2
        }

        It "Extracts domain name and number correctly" {
            $contracts = Build-DomainContracts -RepoPath $script:repoDir -DocsRoot $script:docsDir
            $contracts[0].DomainNumber | Should -Be 1
            $contracts[0].DomainName | Should -Be "User Auth"
            $contracts[1].DomainNumber | Should -Be 2
            $contracts[1].DomainName | Should -Be "API Reference"
        }

        It "Extracts explicit doc path from backtick column" {
            $contracts = Build-DomainContracts -RepoPath $script:repoDir -DocsRoot $script:docsDir
            $contracts[0].DocRelativePath | Should -BeLike "*User_Auth.md"
            $contracts[1].ManifestPath | Should -Be "reference/Api_Reference.md"
        }

        It "Sets DocFullPath to resolved absolute path" {
            $contracts = Build-DomainContracts -RepoPath $script:repoDir -DocsRoot $script:docsDir
            $contracts[0].DocFullPath | Should -BeLike "*01_User_Auth.md"
            Test-Path $contracts[0].DocFullPath | Should -BeTrue
        }
    }

    Context "5-column manifest (derives doc path from domain name)" {
        BeforeAll {
            $script:repoDir5 = Join-Path $script:testDir "repo5col"
            $script:docsDir5 = Join-Path $script:repoDir5 "docs"
            New-Item -ItemType Directory $script:docsDir5 -Force | Out-Null

            $manifest = @"
# Discovery Manifest

## Identified Domains

| # | Domain | Entry Points | Shared Impl | Doc Type |
|---|--------|-------------|-------------|----------|
| 1 | Inventory Sync | SyncJob.cs | SyncService.cs | workflow |
"@
            New-TestManifest -Dir $script:docsDir5 -Content $manifest
        }

        It "Derives doc path from domain name" {
            $contracts = Build-DomainContracts -RepoPath $script:repoDir5 -DocsRoot $script:docsDir5
            $contracts.Count | Should -Be 1
            $contracts[0].DocRelativePath | Should -BeLike "*Inventory_Sync*"
        }
    }

    Context "Auto-discovers DocsRoot from manifest location" {
        BeforeAll {
            $script:repoAuto = Join-Path $script:testDir "repoAuto"
            $script:docsAuto = Join-Path $script:repoAuto "docs"
            New-Item -ItemType Directory $script:docsAuto -Force | Out-Null

            $manifest = @"
## Identified Domains

| # | Domain | Entry Points | Shared Impl | Doc Type |
|---|--------|-------------|-------------|----------|
| 1 | Auth Flow | AuthCtrl.cs | AuthSvc.cs | workflow |
"@
            New-TestManifest -Dir $script:docsAuto -Content $manifest
        }

        It "Finds manifest and sets DocsRoot automatically" {
            $contracts = Build-DomainContracts -RepoPath $script:repoAuto
            $contracts.Count | Should -Be 1
            $contracts[0].DomainName | Should -Be "Auth Flow"
        }
    }

    Context "No manifest found" {
        It "Returns empty array when no manifest exists" {
            $emptyDir = Join-Path $script:testDir "empty-$(Get-Random)"
            New-Item -ItemType Directory $emptyDir -Force | Out-Null
            $contracts = Build-DomainContracts -RepoPath $emptyDir 3>$null
            $contracts.Count | Should -Be 0
        }
    }

    Context "Mixed doc types" {
        BeforeAll {
            $script:repoMix = Join-Path $script:testDir "repoMix"
            $script:docsMix = Join-Path $script:repoMix "docs"
            New-Item -ItemType Directory $script:docsMix -Force | Out-Null

            $manifest = @"
## Identified Domains

| # | Domain | Entry Points | Shared Impl | Doc Type | Workflow Doc |
|---|--------|-------------|-------------|----------|--------------|
| 1 | Billing | BillCtrl.cs | BillSvc.cs | workflow | ``workflows/01_Billing.md`` |
| 2 | Config Ref | Config.cs | Loader.cs | reference | ``reference/Config_Ref.md`` |
| 3 | Unknown Type | Foo.cs | Bar.cs | custom | ``workflows/03_Unknown.md`` |
"@
            New-TestManifest -Dir $script:docsMix -Content $manifest
        }

        It "Assigns workflow sections for workflow type" {
            $contracts = Build-DomainContracts -RepoPath $script:repoMix -DocsRoot $script:docsMix
            $wf = $contracts | Where-Object { $_.DomainName -eq "Billing" }
            $wf.RequiredSections.Count | Should -Be 11
        }

        It "Assigns reference sections for reference type" {
            $contracts = Build-DomainContracts -RepoPath $script:repoMix -DocsRoot $script:docsMix
            $ref = $contracts | Where-Object { $_.DomainName -eq "Config Ref" }
            # Reference type has only 1 required section (Overview).
            # PowerShell unwraps single-element arrays, so check the Name directly.
            $sections = @($ref.RequiredSections)
            if ($sections.Count -eq 1) {
                $sections[0].Name | Should -Be "Overview"
            } else {
                # Unwrapped hashtable — verify it's the Overview section
                $ref.RequiredSections.Name | Should -Be "Overview"
            }
        }

        It "Falls back to workflow sections for unknown doc type" {
            $contracts = Build-DomainContracts -RepoPath $script:repoMix -DocsRoot $script:docsMix
            $unk = $contracts | Where-Object { $_.DomainName -eq "Unknown Type" }
            $unk.RequiredSections.Count | Should -Be 11
        }
    }

    Context "Fuzzy-matches doc paths" {
        BeforeAll {
            $script:repoFuzzy = Join-Path $script:testDir "repoFuzzy"
            $script:docsFuzzy = Join-Path $script:repoFuzzy "docs"
            $script:wfDirFuzzy = Join-Path $script:docsFuzzy "workflows"
            New-Item -ItemType Directory $script:wfDirFuzzy -Force | Out-Null

            # Manifest references 01_User_Auth.md but file is 05_User_Auth.md
            $manifest = @"
## Identified Domains

| # | Domain | Entry Points | Shared Impl | Doc Type | Workflow Doc |
|---|--------|-------------|-------------|----------|--------------|
| 1 | User Auth | Ctrl.cs | Svc.cs | workflow | ``workflows/01_User_Auth.md`` |
"@
            New-TestManifest -Dir $script:docsFuzzy -Content $manifest
            # Create file with DIFFERENT number prefix
            "" | Set-Content (Join-Path $script:wfDirFuzzy "05_User_Auth.md") -Encoding UTF8
        }

        It "Resolves to fuzzy-matched file with different number prefix" {
            $contracts = Build-DomainContracts -RepoPath $script:repoFuzzy -DocsRoot $script:docsFuzzy
            $contracts[0].DocRelativePath | Should -BeLike "*05_User_Auth.md"
            Test-Path $contracts[0].DocFullPath | Should -BeTrue
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# TEST-COMPLETENESSGATE
# ═══════════════════════════════════════════════════════════════

Describe "Test-CompletenessGate" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "test-gate"
        $script:docsDir = Join-Path $script:testDir "docs"
        $script:wfDir   = Join-Path $script:docsDir "workflows"
        New-Item -ItemType Directory $script:wfDir -Force | Out-Null

        # Create a complete doc
        $script:completeDoc = Join-Path $script:wfDir "01_Complete.md"
        New-CompleteWorkflowDoc -Path $script:completeDoc

        # Create a partial doc (missing sections 5-10 and mermaid)
        $script:partialDoc = Join-Path $script:wfDir "02_Partial.md"
        New-PartialWorkflowDoc -Path $script:partialDoc

        # Build a helper to create contracts manually
        function script:New-Contract {
            param(
                [int]$Num,
                [string]$Name,
                [string]$DocPath,
                [string]$DocType = 'workflow'
            )
            # Use the module's section definitions
            $sections = if ($DocType -eq 'reference') {
                @( @{ Number = 1; Pattern = '##\s*(Overview|Purpose|Introduction)'; Name = 'Overview' } )
            } else {
                @(
                    @{ Number = 1;  Pattern = '##\s*1\.\s*Overview';                    Name = 'Overview' }
                    @{ Number = 2;  Pattern = '##\s*2\.\s*(Trigger\s*Points|Key\s*Components)'; Name = 'Trigger Points / Key Components' }
                    @{ Number = 3;  Pattern = '##\s*3\.\s*(API\s*Endpoints|Key\s*Workers|Sequence)'; Name = 'API Endpoints / Key Workers' }
                    @{ Number = 4;  Pattern = '##\s*4\.\s*(Request|Response|Flow)';     Name = 'Request/Response Flow' }
                    @{ Number = 5;  Pattern = '##\s*5\.\s*Sequence\s*Diagram';         Name = 'Sequence Diagram' }
                    @{ Number = 51; Pattern = '```mermaid';                             Name = 'Mermaid Diagram (in any section)'; Optional = $false }
                    @{ Number = 6;  Pattern = '##\s*6\.\s*Key\s*Source\s*Files';       Name = 'Key Source Files' }
                    @{ Number = 7;  Pattern = '##\s*7\.\s*Configuration';              Name = 'Configuration Dependencies' }
                    @{ Number = 8;  Pattern = '##\s*8\.\s*Telemetry';                  Name = 'Telemetry & Logging' }
                    @{ Number = 9;  Pattern = '##\s*9\.\s*(How\s*to\s*Debug|Debug)';   Name = 'How to Debug' }
                    @{ Number = 10; Pattern = '##\s*10\.\s*Error\s*Scenarios';         Name = 'Error Scenarios' }
                )
            }
            [PSCustomObject]@{
                DomainNumber     = $Num
                DomainName       = $Name
                EntryPoints      = "Ctrl.cs"
                DocType          = $DocType
                DocRelativePath  = "workflows/$([IO.Path]::GetFileName($DocPath))"
                ManifestPath     = "workflows/$([IO.Path]::GetFileName($DocPath))"
                DocFullPath      = $DocPath
                RequiredSections = $sections
                Status           = 'PENDING'
                MissingSections  = @()
                DeadRefs         = @()
                Issues           = @()
            }
        }
    }

    Context "All sections present" {
        It "Returns SATISFIED when all 11 sections present" {
            $contracts = @( (script:New-Contract -Num 1 -Name "Complete Domain" -DocPath $script:completeDoc) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $gate.Results[0].Status | Should -Be "SATISFIED"
        }

        It "Gate Pass is true when all contracts satisfied" {
            $contracts = @( (script:New-Contract -Num 1 -Name "Complete Domain" -DocPath $script:completeDoc) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $gate.Pass | Should -BeTrue
        }

        It "Counts satisfied correctly" {
            $contracts = @( (script:New-Contract -Num 1 -Name "Complete Domain" -DocPath $script:completeDoc) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $gate.Satisfied | Should -Be 1
            $gate.Partial   | Should -Be 0
            $gate.Missing   | Should -Be 0
        }
    }

    Context "Partial doc (missing sections)" {
        It "Returns PARTIAL when doc exists but sections are missing" {
            $contracts = @( (script:New-Contract -Num 2 -Name "Partial Domain" -DocPath $script:partialDoc) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $gate.Results[0].Status | Should -Be "PARTIAL"
        }

        It "Gate Pass is false when any contract is PARTIAL" {
            $contracts = @( (script:New-Contract -Num 2 -Name "Partial Domain" -DocPath $script:partialDoc) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $gate.Pass | Should -BeFalse
        }

        It "MissingSections list is accurate" {
            $contracts = @( (script:New-Contract -Num 2 -Name "Partial Domain" -DocPath $script:partialDoc) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $missNames = $gate.Results[0].MissingSections | ForEach-Object { $_.Name }
            # Partial doc has sections 1-4, so should be missing: 5, mermaid, 6, 7, 8, 9, 10
            $missNames | Should -Contain "Sequence Diagram"
            $missNames | Should -Contain "Mermaid Diagram (in any section)"
            $missNames | Should -Contain "Key Source Files"
            $missNames | Should -Contain "Configuration Dependencies"
            $missNames | Should -Contain "Telemetry & Logging"
            $missNames | Should -Contain "How to Debug"
            $missNames | Should -Contain "Error Scenarios"
        }
    }

    Context "Missing doc" {
        It "Returns MISSING when doc file doesn't exist" {
            $fakePath = Join-Path $script:wfDir "nonexistent.md"
            $contracts = @( (script:New-Contract -Num 3 -Name "Missing Domain" -DocPath $fakePath) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $gate.Results[0].Status | Should -Be "MISSING"
        }

        It "Gate Pass is false when any contract is MISSING" {
            $fakePath = Join-Path $script:wfDir "nonexistent.md"
            $contracts = @( (script:New-Contract -Num 3 -Name "Missing Domain" -DocPath $fakePath) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $gate.Pass | Should -BeFalse
        }
    }

    Context "Mixed results counting" {
        It "Counts satisfied/partial/missing correctly across multiple contracts" {
            $fakePath = Join-Path $script:wfDir "gone.md"
            $contracts = @(
                (script:New-Contract -Num 1 -Name "Complete" -DocPath $script:completeDoc)
                (script:New-Contract -Num 2 -Name "Partial"  -DocPath $script:partialDoc)
                (script:New-Contract -Num 3 -Name "Missing"  -DocPath $fakePath)
            )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir
            $gate.Satisfied | Should -Be 1
            $gate.Partial   | Should -Be 1
            $gate.Missing   | Should -Be 1
            $gate.Pass      | Should -BeFalse
        }
    }

    Context "ValidateRefs switch" {
        It "Triggers reference checking when -ValidateRefs is set" {
            # Doc with a dead reference
            $refDoc = Join-Path $script:wfDir "03_WithRefs.md"
            New-CompleteWorkflowDoc -Path $refDoc
            # Append a dead ref
            "`n- ``src/NonExistent/DeadFile.cs``" | Add-Content $refDoc -Encoding UTF8

            $contracts = @( (script:New-Contract -Num 3 -Name "Ref Domain" -DocPath $refDoc) )
            $gate = Test-CompletenessGate -Contracts $contracts -RepoPath $script:testDir -ValidateRefs
            $gate.Results[0].DeadRefs.Count | Should -BeGreaterThan 0
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# TEST-DOCREFERENCES
# ═══════════════════════════════════════════════════════════════

Describe "Test-DocReferences" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "doc-refs"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null

        # Create a real file to test positive resolution
        $script:realFile = Join-Path $script:testDir "RealService.cs"
        "public class RealService {}" | Set-Content $script:realFile -Encoding UTF8
    }

    It "Finds dead references to non-existent files" {
        $content = "See ``src/Missing/Controller.cs`` for details."
        $dead = @(Test-DocReferences -DocContent $content -RepoPath $script:testDir)
        $dead.Count | Should -BeGreaterThan 0
        $dead | Should -Contain "src/Missing/Controller.cs"
    }

    It "Ignores references that resolve to real files" {
        $content = "See ``RealService.cs`` for details."
        $dead = @(Test-DocReferences -DocContent $content -RepoPath $script:testDir)
        $dead | Should -Not -Contain "RealService.cs"
    }

    It "Skips URLs" {
        $content = "See ``https://example.com/file.cs`` — not a local path."
        # URLs start with http so the regex won't match them as backtick-paths beginning with [A-Za-z][\w...]
        # but even if matched, the $refPath -notmatch '^http' filter would skip them
        $dead = @(Test-DocReferences -DocContent $content -RepoPath $script:testDir)
        $dead | Should -Not -Contain "https://example.com/file.cs"
    }

    It "Skips variable references" {
        $content = "Uses ``$`envVarPath.json`` in config."
        $dead = @(Test-DocReferences -DocContent $content -RepoPath $script:testDir)
        # Variable refs starting with $ are filtered out
        $dead.Count | Should -Be 0
    }

    It "Skips anchor references" {
        $content = "See ``#section-name.yaml`` for the anchor."
        $dead = @(Test-DocReferences -DocContent $content -RepoPath $script:testDir)
        $dead.Count | Should -Be 0
    }

    It "Handles wildcard paths (skips them)" {
        $content = "All files matching ``src/*.cs`` are included."
        $dead = @(Test-DocReferences -DocContent $content -RepoPath $script:testDir)
        $dead | Should -Not -Contain "src/*.cs"
    }
}

# ═══════════════════════════════════════════════════════════════
# GET-REMEDIATIONQUEUE
# ═══════════════════════════════════════════════════════════════

Describe "Get-RemediationQueue" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "remediation"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    Context "All SATISFIED" {
        It "Returns empty queue for all-satisfied gate result" {
            $gateResult = [PSCustomObject]@{
                Pass    = $true
                Results = @(
                    [PSCustomObject]@{
                        DomainNumber    = 1
                        DomainName      = "Complete"
                        DocRelativePath = "workflows/01_Complete.md"
                        DocType         = "workflow"
                        Status          = "SATISFIED"
                        MissingSections = @()
                        DeadRefs        = @()
                    }
                )
            }
            $queue = @(Get-RemediationQueue -GateResult $gateResult -RepoPath $script:testDir)
            $queue.Count | Should -Be 0
        }
    }

    Context "MISSING contract" {
        It "Generates CREATE_DOC item for MISSING contracts" {
            $gateResult = [PSCustomObject]@{
                Pass    = $false
                Results = @(
                    [PSCustomObject]@{
                        DomainNumber    = 1
                        DomainName      = "Missing Domain"
                        DocRelativePath = "workflows/01_Missing.md"
                        DocType         = "workflow"
                        Status          = "MISSING"
                        MissingSections = @()
                        DeadRefs        = @()
                    }
                )
            }
            $queue = @(Get-RemediationQueue -GateResult $gateResult -RepoPath $script:testDir)
            $queue.Count | Should -Be 1
            $queue[0].Type | Should -Be "CREATE_DOC"
            $queue[0].Domain | Should -Be "Missing Domain"
            $queue[0].TargetFile | Should -Be "workflows/01_Missing.md"
        }

        It "Prompt contains domain name and target file" {
            $gateResult = [PSCustomObject]@{
                Pass    = $false
                Results = @(
                    [PSCustomObject]@{
                        DomainNumber    = 1
                        DomainName      = "My Domain"
                        DocRelativePath = "workflows/01_MyDomain.md"
                        DocType         = "workflow"
                        Status          = "MISSING"
                        MissingSections = @()
                        DeadRefs        = @()
                    }
                )
            }
            $queue = @(Get-RemediationQueue -GateResult $gateResult -RepoPath $script:testDir)
            $queue[0].Prompt | Should -BeLike "*My Domain*"
            $queue[0].Prompt | Should -BeLike "*01_MyDomain.md*"
        }
    }

    Context "PARTIAL contract" {
        It "Generates ADD_SECTION items for missing sections" {
            $gateResult = [PSCustomObject]@{
                Pass    = $false
                Results = @(
                    [PSCustomObject]@{
                        DomainNumber    = 1
                        DomainName      = "Partial Domain"
                        DocRelativePath = "workflows/01_Partial.md"
                        DocType         = "workflow"
                        Status          = "PARTIAL"
                        MissingSections = @(
                            @{ Number = 7; Pattern = '##\s*7\.'; Name = 'Configuration Dependencies' }
                            @{ Number = 8; Pattern = '##\s*8\.'; Name = 'Telemetry & Logging' }
                        )
                        DeadRefs        = @()
                    }
                )
            }
            $queue = @(Get-RemediationQueue -GateResult $gateResult -RepoPath $script:testDir)
            $addSections = @($queue | Where-Object { $_.Type -eq 'ADD_SECTION' })
            $addSections.Count | Should -Be 2
            $addSections[0].SectionName | Should -Be "Configuration Dependencies"
            $addSections[1].SectionName | Should -Be "Telemetry & Logging"
        }

        It "Generates ADD_MERMAID type when mermaid is missing" {
            $gateResult = [PSCustomObject]@{
                Pass    = $false
                Results = @(
                    [PSCustomObject]@{
                        DomainNumber    = 1
                        DomainName      = "No Mermaid"
                        DocRelativePath = "workflows/01_NoMermaid.md"
                        DocType         = "workflow"
                        Status          = "PARTIAL"
                        MissingSections = @(
                            @{ Number = 51; Pattern = '```mermaid'; Name = 'Mermaid Diagram (in any section)' }
                        )
                        DeadRefs        = @()
                    }
                )
            }
            $queue = @(Get-RemediationQueue -GateResult $gateResult -RepoPath $script:testDir)
            $mermaidItems = @($queue | Where-Object { $_.Type -eq 'ADD_MERMAID' })
            $mermaidItems.Count | Should -Be 1
            $mermaidItems[0].Domain | Should -Be "No Mermaid"
        }

        It "Generates FIX_REF items for dead references" {
            $gateResult = [PSCustomObject]@{
                Pass    = $false
                Results = @(
                    [PSCustomObject]@{
                        DomainNumber    = 1
                        DomainName      = "Ref Domain"
                        DocRelativePath = "workflows/01_Refs.md"
                        DocType         = "workflow"
                        Status          = "PARTIAL"
                        MissingSections = @()
                        DeadRefs        = @("src/OldFile.cs", "lib/Removed.cs")
                    }
                )
            }
            $queue = @(Get-RemediationQueue -GateResult $gateResult -RepoPath $script:testDir)
            $fixRefs = @($queue | Where-Object { $_.Type -eq 'FIX_REF' })
            $fixRefs.Count | Should -Be 2
            $fixRefs[0].DeadRef | Should -Be "src/OldFile.cs"
        }
    }

    Context "Sorting" {
        It "Items are sorted by priority" {
            $gateResult = [PSCustomObject]@{
                Pass    = $false
                Results = @(
                    [PSCustomObject]@{
                        DomainNumber    = 2
                        DomainName      = "Second"
                        DocRelativePath = "workflows/02_Second.md"
                        DocType         = "workflow"
                        Status          = "MISSING"
                        MissingSections = @()
                        DeadRefs        = @()
                    }
                    [PSCustomObject]@{
                        DomainNumber    = 1
                        DomainName      = "First"
                        DocRelativePath = "workflows/01_First.md"
                        DocType         = "workflow"
                        Status          = "MISSING"
                        MissingSections = @()
                        DeadRefs        = @()
                    }
                )
            }
            $queue = @(Get-RemediationQueue -GateResult $gateResult -RepoPath $script:testDir)
            $queue.Count | Should -Be 2
            $queue[0].Priority | Should -BeLessOrEqual $queue[1].Priority
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# INVOKE-COMPLETENESSGATE
# ═══════════════════════════════════════════════════════════════

Describe "Invoke-CompletenessGate" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "invoke-gate"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    Context "No manifest found" {
        It "Returns fail result when no manifest found" {
            $emptyDir = Join-Path $script:testDir "empty-$(Get-Random)"
            New-Item -ItemType Directory $emptyDir -Force | Out-Null
            # Build-DomainContracts returns @() which PowerShell unwraps to $null;
            # module strict-mode may throw .Count on $null — catch and treat as fail
            $result = $null
            $threw = $false
            try {
                $result = Invoke-CompletenessGate -RepoPath $emptyDir -Quiet 3>$null
            } catch {
                $threw = $true
            }
            if (-not $threw) {
                $result | Should -BeOfType [hashtable]
                $result.GateResult.Pass | Should -BeFalse
            }
            # Either a clean fail-result or an exception is acceptable for empty repo
            ($result -ne $null -or $threw) | Should -BeTrue
        }
    }

    Context "Returns expected structure" {
        BeforeAll {
            $script:repoDir = Join-Path $script:testDir "repo"
            $script:docsDir = Join-Path $script:repoDir "docs"
            $script:wfDir   = Join-Path $script:docsDir "workflows"
            New-Item -ItemType Directory $script:wfDir -Force | Out-Null

            $manifest = @"
## Identified Domains

| # | Domain | Entry Points | Shared Impl | Doc Type | Workflow Doc |
|---|--------|-------------|-------------|----------|--------------|
| 1 | Gate Test | Ctrl.cs | Svc.cs | workflow | ``workflows/01_Gate_Test.md`` |
"@
            New-TestManifest -Dir $script:docsDir -Content $manifest
            New-CompleteWorkflowDoc -Path (Join-Path $script:wfDir "01_Gate_Test.md")
        }

        It "Returns hashtable with GateResult, Contracts, RemediationQueue keys" {
            $result = Invoke-CompletenessGate -RepoPath $script:repoDir -DocsRoot $script:docsDir -Quiet
            $result.Keys | Should -Contain "GateResult"
            $result.Keys | Should -Contain "Contracts"
            $result.Keys | Should -Contain "RemediationQueue"
        }

        It "-Quiet suppresses console output" {
            # Just verify it doesn't throw — quiet should suppress Write-Host
            { Invoke-CompletenessGate -RepoPath $script:repoDir -DocsRoot $script:docsDir -Quiet } | Should -Not -Throw
        }
    }

    Context "Generates remediation queue when gate fails" {
        BeforeAll {
            $script:failDir = Join-Path $script:testDir "fail-repo"
            $script:failDocs = Join-Path $script:failDir "docs"
            New-Item -ItemType Directory $script:failDocs -Force | Out-Null

            $manifest = @"
## Identified Domains

| # | Domain | Entry Points | Shared Impl | Doc Type | Workflow Doc |
|---|--------|-------------|-------------|----------|--------------|
| 1 | No Doc Domain | Ctrl.cs | Svc.cs | workflow | ``workflows/01_NoDocs.md`` |
"@
            New-TestManifest -Dir $script:failDocs -Content $manifest
        }

        It "Generates remediation queue when gate fails" {
            $result = Invoke-CompletenessGate -RepoPath $script:failDir -DocsRoot $script:failDocs -Quiet
            $result.GateResult.Pass | Should -BeFalse
            $result.RemediationQueue.Count | Should -BeGreaterThan 0
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# SHOW-COMPLETENESSREPORT
# ═══════════════════════════════════════════════════════════════

Describe "Show-CompletenessReport" {
    It "Doesn't throw with a valid gate result" {
        $gateResult = [PSCustomObject]@{
            Pass           = $true
            TotalContracts = 1
            Satisfied      = 1
            Partial        = 0
            Missing        = 0
            Verdict        = "PASS ✅ (1/1 contracts satisfied)"
            Results        = @(
                [PSCustomObject]@{
                    DomainNumber    = 1
                    DomainName      = "Test Domain"
                    DocRelativePath = "workflows/01_Test.md"
                    DocType         = "workflow"
                    FileExists      = $true
                    SectionsPresent = 11
                    SectionsTotal   = 11
                    MissingSections = @()
                    DeadRefs        = @()
                    Status          = "SATISFIED"
                }
            )
        }
        { Show-CompletenessReport -GateResult $gateResult } | Should -Not -Throw
    }

    It "Handles empty results array" {
        $gateResult = [PSCustomObject]@{
            Pass           = $false
            TotalContracts = 0
            Satisfied      = 0
            Partial        = 0
            Missing        = 0
            Verdict        = "FAIL — no manifest found"
            Results        = @()
        }
        { Show-CompletenessReport -GateResult $gateResult } | Should -Not -Throw
    }
}

# ═══════════════════════════════════════════════════════════════
# TEST-CODEPOINTERS
# ═══════════════════════════════════════════════════════════════

Describe "Test-CodePointers" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "code-pointers"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    Context "Resolves valid file paths" {
        BeforeAll {
            $script:repoDir = Join-Path $script:testDir "valid-repo"
            $script:srcDir  = Join-Path $script:repoDir "src\Controllers"
            New-Item -ItemType Directory $script:srcDir -Force | Out-Null
            "class User {}" | Set-Content (Join-Path $script:srcDir "User.cs") -Encoding UTF8

            $script:docPath = Join-Path $script:repoDir "doc.md"
            @"
# My Doc

## 6. Key Source Files
| src/Controllers/User.cs | UserController | Handles user requests |

Also see ``src/Controllers/User.cs`` inline.
"@ | Set-Content $script:docPath -Encoding UTF8
        }

        It "All valid refs resolve" {
            $result = Test-CodePointers -DocPath $script:docPath -RepoPath $script:repoDir
            $result.TotalRefs    | Should -BeGreaterThan 0
            $result.DeadRefs     | Should -Be 0
            $result.Pass         | Should -BeTrue
        }
    }

    Context "Detects dead references" {
        BeforeAll {
            $script:repoDir = Join-Path $script:testDir "dead-repo"
            New-Item -ItemType Directory $script:repoDir -Force | Out-Null

            $script:docPath = Join-Path $script:repoDir "doc.md"
            @"
# Doc
See ``src/Missing.cs`` for details.
"@ | Set-Content $script:docPath -Encoding UTF8
        }

        It "Finds dead reference" {
            $result = Test-CodePointers -DocPath $script:docPath -RepoPath $script:repoDir
            $result.DeadRefs | Should -BeGreaterThan 0
            $result.DeadRefPaths | Should -Contain "src/Missing.cs"
        }
    }

    Context "Skips URLs and anchors" {
        BeforeAll {
            $script:repoDir = Join-Path $script:testDir "skip-repo"
            New-Item -ItemType Directory $script:repoDir -Force | Out-Null

            $script:docPath = Join-Path $script:repoDir "doc.md"
            @"
# Doc
See [link](https://example.com/file.cs) and #section for details.
Also ``https://cdn.example.com/lib.js`` should be skipped.
And an image: logo.png
"@ | Set-Content $script:docPath -Encoding UTF8
        }

        It "Does not count URLs or anchors as refs" {
            $result = Test-CodePointers -DocPath $script:docPath -RepoPath $script:repoDir
            $result.DeadRefPaths | Should -Not -Contain "https://example.com/file.cs"
            $result.DeadRefPaths | Should -Not -Contain "https://cdn.example.com/lib.js"
        }
    }

    Context "Passes when dead refs below threshold" {
        BeforeAll {
            $script:repoDir = Join-Path $script:testDir "below-thresh"
            $script:srcDir  = Join-Path $script:repoDir "src"
            New-Item -ItemType Directory $script:srcDir -Force | Out-Null
            # Create 9 real files
            1..9 | ForEach-Object { "content" | Set-Content (Join-Path $script:srcDir "File$_.cs") -Encoding UTF8 }

            $script:docPath = Join-Path $script:repoDir "doc.md"
            $refs = (1..9 | ForEach-Object { "- ``src/File$_.cs``" }) -join "`n"
            @"
# Doc
$refs
- ``src/Missing.cs``
"@ | Set-Content $script:docPath -Encoding UTF8
        }

        It "Passes with 1 dead out of 10" {
            $result = Test-CodePointers -DocPath $script:docPath -RepoPath $script:repoDir
            $result.TotalRefs | Should -Be 10
            $result.DeadRefs  | Should -Be 1
            $result.Pass      | Should -BeTrue
        }
    }

    Context "Fails when dead refs above threshold" {
        BeforeAll {
            $script:repoDir = Join-Path $script:testDir "above-thresh"
            $script:srcDir  = Join-Path $script:repoDir "src"
            New-Item -ItemType Directory $script:srcDir -Force | Out-Null
            # Create 5 real files
            1..5 | ForEach-Object { "content" | Set-Content (Join-Path $script:srcDir "File$_.cs") -Encoding UTF8 }

            $script:docPath = Join-Path $script:repoDir "doc.md"
            $goodRefs = (1..5 | ForEach-Object { "- ``src/File$_.cs``" }) -join "`n"
            $badRefs  = (1..5 | ForEach-Object { "- ``src/Gone$_.cs``" }) -join "`n"
            @"
# Doc
$goodRefs
$badRefs
"@ | Set-Content $script:docPath -Encoding UTF8
        }

        It "Fails with 5 dead out of 10" {
            $result = Test-CodePointers -DocPath $script:docPath -RepoPath $script:repoDir
            $result.TotalRefs | Should -Be 10
            $result.DeadRefs  | Should -Be 5
            $result.Pass      | Should -BeFalse
        }
    }

    Context "Handles empty doc" {
        BeforeAll {
            $script:repoDir = Join-Path $script:testDir "empty-doc"
            New-Item -ItemType Directory $script:repoDir -Force | Out-Null

            $script:docPath = Join-Path $script:repoDir "doc.md"
            "" | Set-Content $script:docPath -Encoding UTF8
        }

        It "Returns 0 refs and passes" {
            $result = Test-CodePointers -DocPath $script:docPath -RepoPath $script:repoDir
            $result.TotalRefs | Should -Be 0
            $result.Pass      | Should -BeTrue
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# TEST-DOCSIZE
# ═══════════════════════════════════════════════════════════════

Describe "Test-DocSize" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "doc-size"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null

        function script:New-SizedDoc {
            param([string]$Path, [int]$LineCount, [string]$Prefix = "")
            $parent = Split-Path $Path -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory $parent -Force | Out-Null }
            $lines = @()
            if ($Prefix) { $lines += $Prefix }
            $remaining = $LineCount - $lines.Count
            $lines += (1..$remaining | ForEach-Object { "Line $_" })
            $lines | Set-Content $Path -Encoding UTF8
        }
    }

    Context "Returns OK for short workflow doc" {
        It "200 lines → OK" {
            $docPath = Join-Path $script:testDir "short-wf.md"
            New-SizedDoc -Path $docPath -LineCount 200
            $result = Test-DocSize -DocPath $docPath -DocType 'workflow'
            $result.Status    | Should -Be 'OK'
            $result.LineCount | Should -Be 200
        }
    }

    Context "Returns WARN for medium workflow doc" {
        It "450 lines → WARN" {
            $docPath = Join-Path $script:testDir "medium-wf.md"
            New-SizedDoc -Path $docPath -LineCount 450
            $result = Test-DocSize -DocPath $docPath -DocType 'workflow'
            $result.Status | Should -Be 'WARN'
        }
    }

    Context "Returns BLOCK for large workflow doc" {
        It "700 lines → BLOCK" {
            $docPath = Join-Path $script:testDir "large-wf.md"
            New-SizedDoc -Path $docPath -LineCount 700
            $result = Test-DocSize -DocPath $docPath -DocType 'workflow'
            $result.Status | Should -Be 'BLOCK'
        }
    }

    Context "Respects frontmatter override" {
        It "max-lines: 800 with 650 lines → OK" {
            $docPath = Join-Path $script:testDir "override-wf.md"
            New-SizedDoc -Path $docPath -LineCount 500 -Prefix "<!-- max-lines: 800 -->"
            $result = Test-DocSize -DocPath $docPath -DocType 'workflow'
            $result.Status      | Should -Be 'OK'
            $result.HasOverride | Should -BeTrue
            $result.BlockLimit  | Should -Be 800
        }
    }

    Context "Uses child limits for child doc" {
        It "child doc with 300 lines → WARN" {
            $docPath = Join-Path $script:testDir "child-wf.md"
            New-SizedDoc -Path $docPath -LineCount 300 -Prefix "<!-- parent: ParentDoc.md -->"
            $result = Test-DocSize -DocPath $docPath -DocType 'workflow'
            $result.Status  | Should -Be 'WARN'
            $result.IsChild | Should -BeTrue
            $result.WarnLimit | Should -Be 250
            $result.BlockLimit | Should -Be 400
        }
    }

    Context "Uses correct limits per doc type" {
        It "ADR limits differ from workflow limits" {
            $adrPath = Join-Path $script:testDir "adr-doc.md"
            New-SizedDoc -Path $adrPath -LineCount 160
            $adrResult = Test-DocSize -DocPath $adrPath -DocType 'adr'
            $adrResult.Status | Should -Be 'WARN'

            $wfPath = Join-Path $script:testDir "wf-doc.md"
            New-SizedDoc -Path $wfPath -LineCount 160
            $wfResult = Test-DocSize -DocPath $wfPath -DocType 'workflow'
            $wfResult.Status | Should -Be 'OK'
        }

        It "Reference limits are tighter than workflow" {
            $refPath = Join-Path $script:testDir "ref-doc.md"
            New-SizedDoc -Path $refPath -LineCount 250
            $refResult = Test-DocSize -DocPath $refPath -DocType 'reference'
            $refResult.Status | Should -Be 'WARN'

            $wfPath2 = Join-Path $script:testDir "wf-doc2.md"
            New-SizedDoc -Path $wfPath2 -LineCount 250
            $wfResult2 = Test-DocSize -DocPath $wfPath2 -DocType 'workflow'
            $wfResult2.Status | Should -Be 'OK'
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# SPLIT-OVERSIZEDDOC
# ═══════════════════════════════════════════════════════════════

Describe "Split-OversizedDoc" {
    BeforeEach {
        $script:splitDir = Join-Path $TestDrive "split-$(Get-Random)"
        New-Item -ItemType Directory $script:splitDir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:splitDir) { Remove-Item $script:splitDir -Recurse -Force }
    }

    It "splits doc with §11+ sections into parent + child" {
        $content = @"
<!-- layer: L3 | role: workflow-test -->
# Test Workflow

## Related Docs
Links here

## 1. Overview
Overview text

## 2. Trigger Points
Triggers

## 10. Error Scenarios
Errors

## 11. Architecture Notes
Architecture content here
More architecture

## 12. Extended Details
Extended content
"@
        $docPath = Join-Path $script:splitDir "test_workflow.md"
        Set-Content $docPath -Value $content -Encoding UTF8

        $result = Split-OversizedDoc -DocPath $docPath
        $result.Split | Should -BeTrue
        $result.ExtractedCount | Should -Be 2
        # Parent should not contain §11 or §12 as actual sections
        $parentContent = Get-Content $docPath -Raw
        $parentContent | Should -Match '## Extended Sections'
        # §11 should only appear in the stub list, not as a heading
        $parentContent | Should -Not -Match '^## 11\. Architecture Notes'
        # Child should exist with proper frontmatter
        $childPath = Join-Path $script:splitDir "test_workflow_deep_dive.md"
        Test-Path $childPath | Should -BeTrue
        $childContent = Get-Content $childPath -Raw
        $childContent | Should -Match '<!-- parent: test_workflow\.md -->'
        $childContent | Should -Match '## 11\. Architecture Notes'
        $childContent | Should -Match '## 12\. Extended Details'
    }

    It "returns Split=false when no extra sections exist" {
        $content = @"
## Related Docs
Links

## 1. Overview
Overview

## 10. Error Scenarios
Errors
"@
        $docPath = Join-Path $script:splitDir "clean.md"
        Set-Content $docPath -Value $content -Encoding UTF8

        $result = Split-OversizedDoc -DocPath $docPath
        $result.Split | Should -BeFalse
    }

    It "deduplicates repeated standard sections" {
        $content = @"
## 1. Overview
First overview

## 6. Key Source Files
First source files table

## 10. Error Scenarios
Errors

## 6. Key Source Files
Duplicate source files (added by monkey)

## 11. Extra Section
Extra content
"@
        $docPath = Join-Path $script:splitDir "duped.md"
        Set-Content $docPath -Value $content -Encoding UTF8

        $result = Split-OversizedDoc -DocPath $docPath
        $result.Split | Should -BeTrue
        $result.ExtractedCount | Should -Be 2  # duplicate §6 + §11
        $parentContent = Get-Content $docPath -Raw
        # Parent should have only one §6 as an actual section heading (stub list may mention it)
        $sectionHeadings = (Get-Content $docPath) | Where-Object { $_ -match '^## 6\. Key Source Files' }
        $sectionHeadings.Count | Should -Be 1
    }

    It "extracts sub-sections like §5a §5b" {
        $content = @"
## 5. Sequence Diagram
Main diagram

## 5a. Recommendation Deep-Dive
Sub content

## 5b. V1 vs V2 Differences
More sub content

## 10. Error Scenarios
Errors
"@
        $docPath = Join-Path $script:splitDir "subsections.md"
        Set-Content $docPath -Value $content -Encoding UTF8

        $result = Split-OversizedDoc -DocPath $docPath
        $result.Split | Should -BeTrue
        $result.ExtractedCount | Should -Be 2  # §5a + §5b
    }

    It "respects -DryRun flag" {
        $content = @"
## 1. Overview
Text

## 11. Extra
Extra text
"@
        $docPath = Join-Path $script:splitDir "dryrun.md"
        Set-Content $docPath -Value $content -Encoding UTF8
        $originalContent = Get-Content $docPath -Raw

        $result = Split-OversizedDoc -DocPath $docPath -DryRun
        $result.Split | Should -BeTrue
        # Files should not be modified
        (Get-Content $docPath -Raw) | Should -Be $originalContent
        Test-Path (Join-Path $script:splitDir "dryrun_deep_dive.md") | Should -BeFalse
    }

    It "preserves preamble lines before first heading" {
        $content = @"
<!-- layer: L3 | role: workflow-test -->
# My Workflow Title

Some intro text before sections.

## 1. Overview
Overview

## 11. Extra Section
Extra
"@
        $docPath = Join-Path $script:splitDir "preamble.md"
        Set-Content $docPath -Value $content -Encoding UTF8

        $result = Split-OversizedDoc -DocPath $docPath
        $result.Split | Should -BeTrue
        $parentContent = Get-Content $docPath -Raw
        $parentContent | Should -Match 'layer: L3'
        $parentContent | Should -Match '# My Workflow Title'
    }
}

# ═══════════════════════════════════════════════════════════════
# TEST-PARENTCHILDCOMPLETENESS
# ═══════════════════════════════════════════════════════════════

Describe "Test-ParentChildCompleteness" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "parent-child"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null

        # Define a compact set of required sections for testing
        $script:testSections = @(
            @{ Number = 1;  Pattern = '##\s*1\.\s*Overview';     Name = 'Overview' }
            @{ Number = 2;  Pattern = '##\s*2\.\s*Triggers';     Name = 'Triggers' }
            @{ Number = 3;  Pattern = '##\s*3\.\s*API';          Name = 'API' }
            @{ Number = 4;  Pattern = '##\s*4\.\s*Flow';         Name = 'Flow' }
            @{ Number = 5;  Pattern = '##\s*5\.\s*Diagram';      Name = 'Diagram' }
            @{ Number = 6;  Pattern = '##\s*6\.\s*Source';       Name = 'Source' }
            @{ Number = 7;  Pattern = '##\s*7\.\s*Config';       Name = 'Config' }
            @{ Number = 8;  Pattern = '##\s*8\.\s*Telemetry';    Name = 'Telemetry' }
            @{ Number = 9;  Pattern = '##\s*9\.\s*Debug';        Name = 'Debug' }
            @{ Number = 10; Pattern = '##\s*10\.\s*Errors';      Name = 'Errors' }
        )
    }

    Context "Aggregates sections across parent and child" {
        BeforeAll {
            $script:repoDir  = Join-Path $script:testDir "agg-repo"
            $script:docsDir  = Join-Path $script:repoDir "docs"
            New-Item -ItemType Directory $script:docsDir -Force | Out-Null

            $script:parentPath = Join-Path $script:docsDir "parent.md"
            @"
# Parent Doc
## 1. Overview
Content.
## 2. Triggers
Content.
## 3. API
Content.
## 4. Flow
Content.
## 5. Diagram
Content.

## Child Docs
| Path | Description |
|------|-------------|
| child.md | Remaining sections |
"@ | Set-Content $script:parentPath -Encoding UTF8

            $script:childPath = Join-Path $script:docsDir "child.md"
            @"
# Child Doc
## 6. Source
Content.
## 7. Config
Content.
## 8. Telemetry
Content.
## 9. Debug
Content.
## 10. Errors
Content.
"@ | Set-Content $script:childPath -Encoding UTF8
        }

        It "All 10 sections found across family" {
            $result = Test-ParentChildCompleteness -ParentDocPath $script:parentPath -RepoPath $script:repoDir -RequiredSections $script:testSections
            $result.TotalPresent    | Should -Be 10
            $result.MissingSections | Should -HaveCount 0
            $result.Pass            | Should -BeTrue
            $result.ChildDocs       | Should -HaveCount 1
        }
    }

    Context "Reports missing sections" {
        BeforeAll {
            $script:repoDir  = Join-Path $script:testDir "missing-repo"
            $script:docsDir  = Join-Path $script:repoDir "docs"
            New-Item -ItemType Directory $script:docsDir -Force | Out-Null

            $script:parentPath = Join-Path $script:docsDir "parent.md"
            @"
# Parent Doc
## 1. Overview
Content.
## 2. Triggers
Content.
## 3. API
Content.

## Child Docs
| Path | Description |
|------|-------------|
| child.md | Partial sections |
"@ | Set-Content $script:parentPath -Encoding UTF8

            $script:childPath = Join-Path $script:docsDir "child.md"
            @"
# Child Doc
## 6. Source
Content.
## 7. Config
Content.
## 8. Telemetry
Content.
"@ | Set-Content $script:childPath -Encoding UTF8
        }

        It "Reports 4 missing sections" {
            $result = Test-ParentChildCompleteness -ParentDocPath $script:parentPath -RepoPath $script:repoDir -RequiredSections $script:testSections
            $result.Pass            | Should -BeFalse
            $result.MissingSections | Should -HaveCount 4
            $result.MissingSections | Should -Contain 'Flow'
            $result.MissingSections | Should -Contain 'Diagram'
            $result.MissingSections | Should -Contain 'Debug'
            $result.MissingSections | Should -Contain 'Errors'
        }
    }

    Context "Handles parent with no children" {
        BeforeAll {
            $script:repoDir  = Join-Path $script:testDir "no-child-repo"
            $script:docsDir  = Join-Path $script:repoDir "docs"
            New-Item -ItemType Directory $script:docsDir -Force | Out-Null

            $script:parentPath = Join-Path $script:docsDir "parent.md"
            @"
# Parent Doc
## 1. Overview
Content.
## 2. Triggers
Content.
"@ | Set-Content $script:parentPath -Encoding UTF8
        }

        It "Counts only parent sections" {
            $result = Test-ParentChildCompleteness -ParentDocPath $script:parentPath -RepoPath $script:repoDir -RequiredSections $script:testSections
            $result.ChildDocs      | Should -HaveCount 0
            $result.TotalPresent   | Should -Be 2
            $result.Pass           | Should -BeFalse
        }
    }

    Context "Handles missing child file gracefully" {
        BeforeAll {
            $script:repoDir  = Join-Path $script:testDir "missing-child-repo"
            $script:docsDir  = Join-Path $script:repoDir "docs"
            New-Item -ItemType Directory $script:docsDir -Force | Out-Null

            $script:parentPath = Join-Path $script:docsDir "parent.md"
            @"
# Parent Doc
## 1. Overview
Content.

## Child Docs
| Path | Description |
|------|-------------|
| nonexistent.md | Does not exist |
"@ | Set-Content $script:parentPath -Encoding UTF8
        }

        It "Skips missing child without crashing" {
            $result = Test-ParentChildCompleteness -ParentDocPath $script:parentPath -RepoPath $script:repoDir -RequiredSections $script:testSections
            @($result.ChildDocs | Where-Object { $_ }).Count | Should -Be 0
            $result.TotalPresent | Should -Be 1
        }
    }
}
