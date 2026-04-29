<#
.SYNOPSIS
    CompletenessGate.psm1 — Contract-based documentation completeness validation.
.DESCRIPTION
    Provides DAG-like fullness, completeness, and predictability guarantees
    for the Monkey Army documentation framework.

    Three core functions:
    1. Build-DomainContracts  — Parse Discovery_Manifest → typed contracts
    2. Test-CompletenessGate  — Validate all contracts against filesystem
    3. Get-RemediationQueue   — Generate deterministic fix prompts for gaps
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════
# CONTRACT DEFINITIONS — Typed section requirements per doc kind
# ═══════════════════════════════════════════════════════════════

# Primary workflow docs: 10 universally required sections
$script:PrimaryWorkflowSections = @(
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

# Reference docs: lighter requirements
$script:ReferenceDocSections = @(
    @{ Number = 1; Pattern = '##\s*(Overview|Purpose|Introduction)';    Name = 'Overview' }
)

# ADR docs: decision record format
$script:AdrSections = @(
    @{ Number = 1; Pattern = '##\s*(Context|Background|Problem)';       Name = 'Context' }
    @{ Number = 2; Pattern = '##\s*(Decision|Resolution|Approach)';     Name = 'Decision' }
    @{ Number = 3; Pattern = '##\s*(Status|Consequences|Impact)';       Name = 'Status / Consequences' }
)

# ═══════════════════════════════════════════════════════════════
# BUILD CONTRACTS — Parse Discovery_Manifest → typed contracts
# ═══════════════════════════════════════════════════════════════

function Build-DomainContracts {
    <#
    .SYNOPSIS
        Parses Discovery_Manifest.md to extract domain contracts.
    .DESCRIPTION
        Reads the Identified Domains table from the manifest and builds
        a typed contract for each domain with expected doc path, doc type,
        and required sections.
    .PARAMETER RepoPath
        Path to the repository root.
    .PARAMETER ManifestPath
        Optional override for manifest file path. Auto-discovered if omitted.
    .OUTPUTS
        Array of contract objects.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$ManifestPath,
        [string]$DocsRoot
    )

    # Auto-discover DOCS_ROOT if not provided
    if (-not $DocsRoot) {
        # Search for Discovery_Manifest.md anywhere under the repo
        $manifestCandidates = @(
            (Get-ChildItem -Path $RepoPath -Recurse -Filter "Discovery_Manifest.md" -ErrorAction SilentlyContinue |
                Select-Object -First 3)
        )
        if ($manifestCandidates.Count -gt 0) {
            $DocsRoot = $manifestCandidates[0].Directory.FullName
            if (-not $ManifestPath) { $ManifestPath = $manifestCandidates[0].FullName }
        } else {
            # Fallback: check common DOCS_ROOT patterns
            $commonRoots = @("docs\knowledge", "docs\knowledge", "docs", "copilot-docs")
            foreach ($root in $commonRoots) {
                $candidate = Join-Path $RepoPath $root
                if (Test-Path $candidate) { $DocsRoot = $candidate; break }
            }
        }
    }

    # Auto-discover manifest if still not found
    if (-not $ManifestPath) {
        if ($DocsRoot) {
            $mPath = Join-Path $DocsRoot "Discovery_Manifest.md"
            if (Test-Path $mPath) { $ManifestPath = $mPath }
        }
        # Legacy fallback
        if (-not $ManifestPath) {
            $legacyCandidates = @(
                (Join-Path $RepoPath "docs\knowledge\Discovery_Manifest.md"),
                (Join-Path $RepoPath "docs\knowledge\discovery_manifest.md"),
                (Join-Path $RepoPath "docs\Discovery_Manifest.md")
            )
            foreach ($c in $legacyCandidates) {
                if (Test-Path $c) { $ManifestPath = $c; break }
            }
        }
    }

    # Derive DocsRoot from manifest location if we have manifest but no DocsRoot
    if ($ManifestPath -and -not $DocsRoot) {
        $DocsRoot = Split-Path $ManifestPath -Parent
    }

    if (-not $ManifestPath -or -not (Test-Path $ManifestPath)) {
        Write-Warning "Discovery Manifest not found at expected paths. No contracts generated."
        return @()
    }

    $content = Get-Content $ManifestPath -Raw -Encoding UTF8

    # Parse the Identified Domains table
    # Format: | # | Domain Name | Entry Points | Shared Impl | Doc Type | Workflow Doc |
    # Also supports 5-column format (without Workflow Doc) — derives doc path from domain name
    $contracts = @()
    $tableLines = $content -split "`n" | Where-Object { $_ -match '^\|\s*\d+\s*\|' }

    foreach ($line in $tableLines) {
        $cells = ($line -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($cells.Count -lt 5) { continue }

        $domainNum    = $cells[0].Trim()
        $domainName   = $cells[1].Trim()
        $entryPoints  = $cells[2].Trim()
        $sharedImpl   = $cells[3].Trim()
        $docType      = $cells[4].Trim().ToLower()

        # 6-column format has explicit Workflow Doc; 5-column derives from domain name
        $workflowDoc = if ($cells.Count -ge 6) { $cells[5].Trim() } else { "" }

        # Extract relative path from backticks: `workflows/01_Domain_Name.md`
        $docRelPath = if ($workflowDoc -match '`([^`]+\.md)`') {
            $matches[1]
        } elseif ($workflowDoc -and $workflowDoc -match '\.md') {
            $workflowDoc
        } else {
            # Derive from domain name: "User Auth" → "workflows/User_Auth.md"
            $safeName = ($domainName -replace '[/\\:\s]+', '_' -replace '[^\w_]', '')
            "workflows/${safeName}.md"
        }

        # Determine required sections based on doc type
        $requiredSections = switch -Regex ($docType) {
            'workflow'  { $script:PrimaryWorkflowSections }
            'reference' { $script:ReferenceDocSections }
            default     { $script:PrimaryWorkflowSections }  # default to workflow standard
        }

        # Resolve doc path using DocsRoot (not hardcoded)
        $docFullPath = Join-Path $DocsRoot $docRelPath
        $resolvedRelPath = $docRelPath

        if (-not (Test-Path $docFullPath)) {
            # Extract the descriptive part of the filename (after number prefix)
            $docFileName = [IO.Path]::GetFileNameWithoutExtension($docRelPath)
            $keyword = ($docFileName -replace '^\d+_', '')  # strip leading number_
            if ($keyword) {
                $workflowDir = Join-Path $DocsRoot "workflows"
                if (Test-Path $workflowDir) {
                    $fuzzyMatch = Get-ChildItem $workflowDir -Filter "*${keyword}*.md" -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match "^\d+_" } |
                        Select-Object -First 1
                    if ($fuzzyMatch) {
                        $resolvedRelPath = "workflows/$($fuzzyMatch.Name)"
                        $docFullPath = $fuzzyMatch.FullName
                    }
                }
            }
        }

        $contracts += [PSCustomObject]@{
            DomainNumber    = [int]$domainNum
            DomainName      = $domainName
            EntryPoints     = $entryPoints
            DocType         = $docType
            DocRelativePath = $resolvedRelPath
            ManifestPath    = $docRelPath
            DocFullPath     = $docFullPath
            RequiredSections = $requiredSections
            Status          = 'PENDING'
            MissingSections = @()
            DeadRefs        = @()
            Issues          = @()
        }
    }

    Write-Host "  [INFO] Built $($contracts.Count) domain contracts from manifest" -ForegroundColor Cyan
    return $contracts
}

# ═══════════════════════════════════════════════════════════════
# TEST GATE — Validate all contracts against filesystem
# ═══════════════════════════════════════════════════════════════

function Test-CompletenessGate {
    <#
    .SYNOPSIS
        Validates all domain contracts against the actual filesystem.
    .DESCRIPTION
        For each contract:
        1. Checks doc file exists on disk
        2. Validates required section headers are present
        3. Checks that code references resolve to real files
        Returns a gate result with per-domain status.
    .PARAMETER Contracts
        Array of contracts from Build-DomainContracts.
    .PARAMETER RepoPath
        Path to the repository root.
    .PARAMETER ValidateRefs
        If true, also validates code file references in docs. Default: false.
    .OUTPUTS
        Gate result object with Pass/Fail, per-domain results, and remediation items.
    #>
    param(
        [Parameter(Mandatory)][array]$Contracts,
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$ValidateRefs
    )

    $results = @()
    $satisfied = 0
    $partial = 0
    $missing = 0

    foreach ($contract in $Contracts) {
        $result = [PSCustomObject]@{
            DomainNumber    = $contract.DomainNumber
            DomainName      = $contract.DomainName
            DocRelativePath = $contract.DocRelativePath
            DocType         = $contract.DocType
            FileExists      = $false
            SectionsTotal   = $contract.RequiredSections.Count
            SectionsPresent = 0
            MissingSections = @()
            DeadRefs        = @()
            Status          = 'MISSING'
        }

        # Check 1: File exists on disk
        if (Test-Path $contract.DocFullPath) {
            $result.FileExists = $true
            $docContent = Get-Content $contract.DocFullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue

            if ($docContent) {
                # Check 2: Required sections present
                $missingSections = @()
                foreach ($section in $contract.RequiredSections) {
                    if ($docContent -notmatch $section.Pattern) {
                        $missingSections += $section
                    }
                }
                $result.SectionsPresent = $contract.RequiredSections.Count - $missingSections.Count
                $result.MissingSections = $missingSections

                # Check 3: Code references resolve (optional, lightweight)
                if ($ValidateRefs) {
                    $result.DeadRefs = @(Test-DocReferences -DocContent $docContent -RepoPath $RepoPath)
                }

                # Determine status
                if ($missingSections.Count -eq 0) {
                    $result.Status = 'SATISFIED'
                    $satisfied++
                } else {
                    $result.Status = 'PARTIAL'
                    $partial++
                }
            } else {
                $result.Status = 'PARTIAL'
                $partial++
            }
        } else {
            $result.Status = 'MISSING'
            $missing++
        }

        $results += $result
    }

    $totalContracts = $Contracts.Count
    $gatePass = ($missing -eq 0) -and ($partial -eq 0)

    $gateResult = [PSCustomObject]@{
        Pass            = $gatePass
        TotalContracts  = $totalContracts
        Satisfied       = $satisfied
        Partial         = $partial
        Missing         = $missing
        Results         = $results
        Verdict         = if ($gatePass) { "PASS ✅ ($satisfied/$totalContracts contracts satisfied)" }
                          else { "FAIL ❌ ($satisfied/$totalContracts satisfied, $partial partial, $missing missing)" }
    }

    return $gateResult
}

# ═══════════════════════════════════════════════════════════════
# REFERENCE VALIDATOR — Check code refs in docs resolve
# ═══════════════════════════════════════════════════════════════

function Test-DocReferences {
    <#
    .SYNOPSIS
        Checks that source file references in a doc resolve to real files.
    #>
    param(
        [string]$DocContent,
        [string]$RepoPath
    )

    $deadRefs = @()

    # Match backtick paths that look like source files
    $refMatches = [regex]::Matches($DocContent, '`([A-Za-z][\w\\\/\.\-]+\.(cs|py|js|ts|json|xml|yml|yaml|config))`')
    foreach ($match in $refMatches) {
        $refPath = $match.Groups[1].Value
        # Normalize path separators
        $normalizedRef = $refPath -replace '/', '\'

        # Try to find the file in the repo
        $found = $false
        $searchPath = Join-Path $RepoPath $normalizedRef
        if (Test-Path $searchPath) { $found = $true }

        # Try partial match under src/
        if (-not $found) {
            $srcPath = Join-Path $RepoPath "src" $normalizedRef
            if (Test-Path $srcPath) { $found = $true }
        }

        # Try wildcard if path contains *
        if (-not $found -and $refPath -match '\*') { $found = $true }  # skip wildcard paths

        if (-not $found -and $refPath -notmatch '^\$|^http|^#|^\{') {
            $deadRefs += $refPath
        }
    }

    return $deadRefs
}

# ═══════════════════════════════════════════════════════════════
# REMEDIATION QUEUE — Deterministic fix prompts for gaps
# ═══════════════════════════════════════════════════════════════

function Get-RemediationQueue {
    <#
    .SYNOPSIS
        Generates deterministic remediation prompts from gate results.
    .DESCRIPTION
        For each PARTIAL or MISSING contract, generates a specific, actionable
        prompt that can be fed to Copilot to fix the gap. These are deterministic —
        same gap always produces the same prompt.
    .PARAMETER GateResult
        Output from Test-CompletenessGate.
    .PARAMETER RepoPath
        Path to the repository root.
    .OUTPUTS
        Array of remediation items with priority, target file, and prompt.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$GateResult,
        [Parameter(Mandatory)][string]$RepoPath
    )

    $queue = @()
    $priority = 0

    foreach ($result in $GateResult.Results) {
        if ($result.Status -eq 'SATISFIED') { continue }

        $priority++

        if ($result.Status -eq 'MISSING') {
            # Entire doc is missing — generate creation prompt
            $queue += [PSCustomObject]@{
                Priority    = $priority
                Type        = 'CREATE_DOC'
                Domain      = $result.DomainName
                TargetFile  = $result.DocRelativePath
                Prompt      = @"
Create the workflow documentation file '$($result.DocRelativePath)' for the '$($result.DomainName)' domain.

The document MUST contain these required sections:
$(($result | ForEach-Object { $_.MissingSections } | ForEach-Object { "- ## $($_.Number). $($_.Name)" }) -join "`n")

Follow the same format as existing workflow docs in the workflows/ folder.
Include: overview, entry points, request flow, sequence diagram, source files, config, telemetry, debugging, error scenarios.
Base all content on actual source code analysis — do not fabricate.
"@
            }
        }
        elseif ($result.Status -eq 'PARTIAL') {
            # Doc exists but missing sections
            foreach ($missing in $result.MissingSections) {
                $isMermaid = $missing.Name -match 'Mermaid'
                $sectionPrompt = if ($isMermaid) {
                    @"
In the file '$($result.DocRelativePath)', add a Mermaid sequence diagram in the '## 5. Sequence Diagram' section (or create the section if missing).

The diagram MUST follow these rules from the Playbook standard:
- Use REAL method names from source code (not generic "process request")
- Show decision points with alt/opt blocks for branching logic
- Include error paths (catch blocks, fallbacks) as alt branches
- Show config checks that change flow direction
- Minimum 4 participants for any cross-layer flow
- For complex flows, split into multiple diagrams (happy path + error path)

Example format:
``````mermaid
sequenceDiagram
  participant Client
  participant Controller
  participant BL as Business Logic
  participant Impl as Implementation
  Client->>Controller: HTTP verb /route
  Controller->>BL: RealMethodName()
  BL->>Impl: ActualImplementation()
  Impl-->>BL: Response
``````

Analyze the actual source code for the '$($result.DomainName)' domain to build an accurate diagram.
"@
                } else {
                    @"
In the file '$($result.DocRelativePath)', add the missing section '## $($missing.Number). $($missing.Name)'.

This section should follow the same depth and format as other sections in the document.
Place it in numerical order relative to existing sections.
Base all content on actual source code analysis of the '$($result.DomainName)' domain — do not fabricate.
"@
                }

                $queue += [PSCustomObject]@{
                    Priority    = $priority
                    Type        = if ($isMermaid) { 'ADD_MERMAID' } else { 'ADD_SECTION' }
                    Domain      = $result.DomainName
                    TargetFile  = $result.DocRelativePath
                    SectionName = $missing.Name
                    SectionNum  = $missing.Number
                    Prompt      = $sectionPrompt
                }
            }

            # Dead references
            foreach ($deadRef in $result.DeadRefs) {
                $queue += [PSCustomObject]@{
                    Priority    = $priority + 100  # lower priority than missing sections
                    Type        = 'FIX_REF'
                    Domain      = $result.DomainName
                    TargetFile  = $result.DocRelativePath
                    DeadRef     = $deadRef
                    Prompt      = "In '$($result.DocRelativePath)', the reference to '$deadRef' points to a file that no longer exists. Find the correct current path or remove the reference."
                }
            }
        }
    }

    # Sort by priority
    $queue = @($queue | Sort-Object Priority)

    return $queue
}

# ═══════════════════════════════════════════════════════════════
# DISPLAY — Pretty-print gate results
# ═══════════════════════════════════════════════════════════════

function Show-CompletenessReport {
    <#
    .SYNOPSIS
        Displays the completeness gate results in a formatted table.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$GateResult
    )

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          📋 COMPLETENESS GATE                           ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # Table header
    $fmt = "  {0,-4} {1,-40} {2,-12} {3,-8} {4}"
    Write-Host ($fmt -f "#", "DOMAIN", "SECTIONS", "STATUS", "DOC") -ForegroundColor White
    Write-Host ("  " + "─" * 85) -ForegroundColor DarkGray

    foreach ($r in $GateResult.Results | Sort-Object DomainNumber) {
        $statusColor = switch ($r.Status) {
            'SATISFIED' { 'Green' }
            'PARTIAL'   { 'Yellow' }
            'MISSING'   { 'Red' }
        }
        $statusIcon = switch ($r.Status) {
            'SATISFIED' { '✅' }
            'PARTIAL'   { '⚠️' }
            'MISSING'   { '❌' }
        }
        $sectionStr = if ($r.FileExists) { "$($r.SectionsPresent)/$($r.SectionsTotal)" } else { "N/A" }

        Write-Host ("  {0,-4} " -f $r.DomainNumber) -ForegroundColor White -NoNewline
        Write-Host ("{0,-40} " -f ($r.DomainName.Substring(0, [Math]::Min(39, $r.DomainName.Length)))) -ForegroundColor White -NoNewline
        Write-Host ("{0,-12} " -f $sectionStr) -ForegroundColor White -NoNewline
        Write-Host ("{0,-8} " -f "$statusIcon $($r.Status)") -ForegroundColor $statusColor -NoNewline
        Write-Host $r.DocRelativePath -ForegroundColor DarkGray

        # Show missing sections inline
        if ($r.MissingSections.Count -gt 0) {
            $missingNames = ($r.MissingSections | ForEach-Object { "§$($_.Number)" }) -join ', '
            Write-Host ("       └─ Missing: $missingNames") -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $verdictColor = if ($GateResult.Pass) { 'Green' } else { 'Red' }
    Write-Host "  $($GateResult.Verdict)" -ForegroundColor $verdictColor
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════
# ORCHESTRATOR INTEGRATION — Full gate check with optional heal
# ═══════════════════════════════════════════════════════════════

function Invoke-CompletenessGate {
    <#
    .SYNOPSIS
        Full completeness gate check — build contracts, validate, report, and
        optionally generate remediation queue.
    .PARAMETER RepoPath
        Path to the repository root.
    .PARAMETER ValidateRefs
        Also validate code file references in docs.
    .PARAMETER Quiet
        Suppress display output (for programmatic use).
    .OUTPUTS
        Hashtable with: GateResult, Contracts, RemediationQueue
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$ValidateRefs,
        [switch]$Quiet,
        [string]$DocsRoot
    )

    # Step 1: Build contracts from manifest
    $contracts = Build-DomainContracts -RepoPath $RepoPath -DocsRoot $DocsRoot

    if ($contracts.Count -eq 0) {
        Write-Warning "No domain contracts found. Completeness gate FAILED — no manifest discovered."
        return @{
            GateResult       = [PSCustomObject]@{ Pass = $false; Verdict = "FAIL — no manifest found"; Results = @() }
            Contracts        = @()
            RemediationQueue = @()
        }
    }

    # Step 2: Validate contracts against filesystem
    $gateResult = Test-CompletenessGate -Contracts $contracts -RepoPath $RepoPath -ValidateRefs:$ValidateRefs

    # Step 3: Display report
    if (-not $Quiet) {
        Show-CompletenessReport -GateResult $gateResult
    }

    # Step 4: Generate remediation queue if gate failed
    $remediationQueue = @()
    if (-not $gateResult.Pass) {
        $remediationQueue = Get-RemediationQueue -GateResult $gateResult -RepoPath $RepoPath
        if (-not $Quiet -and $remediationQueue.Count -gt 0) {
            Write-Host "  📝 Remediation queue: $($remediationQueue.Count) items" -ForegroundColor Yellow
            foreach ($item in $remediationQueue | Select-Object -First 5) {
                Write-Host "     [$($item.Type)] $($item.Domain) → $($item.TargetFile)" -ForegroundColor Yellow
            }
            if ($remediationQueue.Count -gt 5) {
                Write-Host "     ... and $($remediationQueue.Count - 5) more" -ForegroundColor DarkGray
            }
        }
    }

    return @{
        GateResult       = $gateResult
        Contracts        = $contracts
        RemediationQueue = $remediationQueue
    }
}

# ═══════════════════════════════════════════════════════════════
# CODE POINTER VALIDATION — Verify file refs in markdown docs
# ═══════════════════════════════════════════════════════════════

function Test-CodePointers {
    <#
    .SYNOPSIS
        Extracts file path references from a markdown doc and verifies they resolve on disk.
    .PARAMETER DocPath
        Path to the markdown document.
    .PARAMETER RepoPath
        Path to the repository root.
    .PARAMETER DeadRefThreshold
        Maximum allowed dead reference rate (0.0–1.0). Default 0.20.
    .OUTPUTS
        Hashtable with TotalRefs, ResolvedRefs, DeadRefs, DeadRefPaths, DeadRefRate, Pass.
    #>
    param(
        [Parameter(Mandatory)][string]$DocPath,
        [Parameter(Mandatory)][string]$RepoPath,
        [double]$DeadRefThreshold = 0.20
    )

    $result = @{
        DocPath      = $DocPath
        TotalRefs    = 0
        ResolvedRefs = 0
        DeadRefs     = 0
        DeadRefPaths = @()
        DeadRefRate  = 0.0
        Pass         = $true
    }

    if (-not (Test-Path $DocPath)) { return $result }

    $content = Get-Content $DocPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) { return $result }

    # ── Collect all file path references ──
    $allRefs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Pattern 1: Backtick paths — `path/to/file.ext`
    $backtickMatches = [regex]::Matches($content, '`([A-Za-z][\w\\\/\.\-]+\.\w+)`')
    foreach ($m in $backtickMatches) { [void]$allRefs.Add($m.Groups[1].Value) }

    # Pattern 2: Section 6 table entries — | path/file.ext | ClassName | Purpose |
    $tableMatches = [regex]::Matches($content, '(?m)^\|\s*([A-Za-z][\w\\\/\.\-]+\.\w+)\s*\|')
    foreach ($m in $tableMatches) { [void]$allRefs.Add($m.Groups[1].Value) }

    # Pattern 3: Bare paths with src/, lib/, app/, cmd/ prefix
    $bareMatches = [regex]::Matches($content, '(?<![`\[(/])(?:src|lib|app|cmd)/[\w/\.\-]+\.\w+')
    foreach ($m in $bareMatches) { [void]$allRefs.Add($m.Value) }

    # ── Filter out non-file refs ──
    $skipPattern = '^https?://|^#|\.(?:png|jpg|jpeg|svg|gif)$'
    $filteredRefs = @($allRefs | Where-Object { $_ -notmatch $skipPattern })

    $result.TotalRefs = $filteredRefs.Count
    if ($filteredRefs.Count -eq 0) { return $result }

    # ── Resolve each ref ──
    $deadPaths = @()
    foreach ($ref in $filteredRefs) {
        $normalizedRef = $ref -replace '/', '\'
        $found = $false

        # a) Exact path
        $exactPath = Join-Path $RepoPath $normalizedRef
        if (Test-Path $exactPath) { $found = $true }

        # b) Under src/
        if (-not $found) {
            $srcPath = Join-Path $RepoPath "src" $normalizedRef
            if (Test-Path $srcPath) { $found = $true }
        }

        # c) Wildcard / glob
        if (-not $found -and $ref -match '\*') { $found = $true }

        if (-not $found) { $deadPaths += $ref }
    }

    $result.DeadRefs     = $deadPaths.Count
    $result.DeadRefPaths = $deadPaths
    $result.ResolvedRefs = $filteredRefs.Count - $deadPaths.Count
    $result.DeadRefRate  = if ($filteredRefs.Count -gt 0) { [double]$deadPaths.Count / $filteredRefs.Count } else { 0.0 }
    $result.Pass         = $result.DeadRefRate -le $DeadRefThreshold

    return $result
}

# ═══════════════════════════════════════════════════════════════
# DOC SIZE ENFORCEMENT — Line count limits per doc type
# ═══════════════════════════════════════════════════════════════

$script:DocSizeLimits = @{
    'workflow'  = @{ Warn = 400; Block = 600 }
    'reference' = @{ Warn = 200; Block = 400 }
    'adr'       = @{ Warn = 150; Block = 300 }
    'general'   = @{ Warn = 300; Block = 500 }
}

$script:ChildLimits = @{ Warn = 250; Block = 400 }

function Test-DocSize {
    <#
    .SYNOPSIS
        Checks doc line counts against per-type limits.
    .PARAMETER DocPath
        Path to the markdown document.
    .PARAMETER DocType
        One of: workflow, reference, adr, general.
    .PARAMETER WarnLimit
        Override warn limit.
    .PARAMETER BlockLimit
        Override block limit.
    .OUTPUTS
        Hashtable with LineCount, DocType, WarnLimit, BlockLimit, HasOverride, IsChild, Status.
    #>
    param(
        [Parameter(Mandatory)][string]$DocPath,
        [Parameter(Mandatory)][ValidateSet('workflow','reference','adr','general')][string]$DocType,
        [int]$WarnLimit,
        [int]$BlockLimit
    )

    $lines = @(Get-Content $DocPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    $lineCount = $lines.Count
    $content = $lines -join "`n"

    # Determine base limits from doc type
    $baseLimits = $script:DocSizeLimits[$DocType]
    $effectiveWarn  = $baseLimits.Warn
    $effectiveBlock = $baseLimits.Block
    $hasOverride = $false
    $isChild = $false

    # Check for frontmatter override: <!-- max-lines: N -->
    if ($content -match '<!--\s*max-lines:\s*(\d+)\s*-->') {
        $overrideBlock = [int]$Matches[1]
        $effectiveBlock = $overrideBlock
        $effectiveWarn  = [Math]::Floor($overrideBlock * 0.7)
        $hasOverride = $true
    }

    # Check for parent/child: <!-- parent: X -->
    if ($content -match '<!--\s*parent:\s*.+\s*-->') {
        $isChild = $true
        if (-not $hasOverride) {
            $effectiveWarn  = $script:ChildLimits.Warn
            $effectiveBlock = $script:ChildLimits.Block
        }
    }

    # Explicit parameter overrides take highest priority
    if ($PSBoundParameters.ContainsKey('WarnLimit'))  { $effectiveWarn  = $WarnLimit }
    if ($PSBoundParameters.ContainsKey('BlockLimit')) { $effectiveBlock = $BlockLimit }

    # Determine status
    $status = if ($lineCount -ge $effectiveBlock) { 'BLOCK' }
              elseif ($lineCount -ge $effectiveWarn) { 'WARN' }
              else { 'OK' }

    return @{
        DocPath     = $DocPath
        LineCount   = $lineCount
        DocType     = $DocType
        WarnLimit   = $effectiveWarn
        BlockLimit  = $effectiveBlock
        HasOverride = $hasOverride
        IsChild     = $isChild
        Status      = $status
    }
}

function Split-OversizedDoc {
    <#
    .SYNOPSIS
        Splits an oversized workflow doc by extracting §11+ and duplicate sections
        into a companion *_deep_dive.md file.
    .PARAMETER DocPath
        Path to the oversized markdown document.
    .PARAMETER DryRun
        Preview changes without writing files.
    .OUTPUTS
        Hashtable with Split (bool), ParentPath, ChildPath, ExtractedCount,
        OriginalLines, NewParentLines, ChildLines.
    #>
    param(
        [Parameter(Mandatory)][string]$DocPath,
        [switch]$DryRun
    )

    $lines = @(Get-Content $DocPath -Encoding UTF8)
    $originalCount = $lines.Count

    # Parse sections (## headings)
    $sections = @()
    $currentStart = $null
    $currentHeading = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## ') {
            if ($null -ne $currentStart) {
                $sections += @{
                    Start   = $currentStart
                    End     = $i - 1
                    Heading = $currentHeading
                    Lines   = $lines[$currentStart..($i - 1)]
                }
            }
            $currentStart = $i
            $currentHeading = $lines[$i]
        }
    }
    if ($null -ne $currentStart) {
        $sections += @{
            Start   = $currentStart
            End     = $lines.Count - 1
            Heading = $currentHeading
            Lines   = $lines[$currentStart..($lines.Count - 1)]
        }
    }

    # Classify: core (§0-§10 first occurrence) vs extra (§11+, sub-sections, duplicates)
    $coreSections = @()
    $extraSections = @()
    $seenNumbers = @{}

    foreach ($section in $sections) {
        $num = -1
        if ($section.Heading -match '^## (\d+)[a-f]?\.?\s') { $num = [int]$Matches[1] }
        elseif ($section.Heading -match '^## Related') { $num = 0 }

        $isExtra = $false
        if ($num -ge 11) { $isExtra = $true }
        elseif ($section.Heading -match '^## \d+[a-f][\.\s]' -or $section.Heading -match '^## 5[1-9]') { $isExtra = $true }
        elseif ($num -ge 0 -and $seenNumbers.ContainsKey($num)) { $isExtra = $true }

        if (-not $isExtra) {
            $coreSections += $section
            if ($num -ge 0) { $seenNumbers[$num] = $true }
        } else {
            $extraSections += $section
        }
    }

    if ($extraSections.Count -eq 0) {
        return @{ Split = $false; Reason = 'No extra sections to extract' }
    }

    # Build file paths
    $dir = Split-Path $DocPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($DocPath)
    $parentFileName = [System.IO.Path]::GetFileName($DocPath)
    $childName = "${baseName}_deep_dive.md"
    $childPath = Join-Path $dir $childName

    # Build child doc
    $childLines = @(
        "<!-- layer: L3 | role: workflow-${baseName}-deep-dive -->"
        "<!-- parent: $parentFileName -->"
        ""
        "# $baseName - Deep Dive Sections"
        ""
        "> Extended sections extracted from [$parentFileName](./$parentFileName)."
        ""
    )
    $movedHeadings = @()
    foreach ($extra in $extraSections) {
        $childLines += $extra.Lines
        $childLines += ""
        $clean = ($extra.Heading -replace '<!--.*?-->', '').Trim()
        $movedHeadings += "- $clean"
    }

    # Rebuild parent: preamble + core + stub
    $firstHeading = ($sections | Select-Object -First 1).Start
    $preamble = if ($firstHeading -gt 0) { $lines[0..($firstHeading - 1)] } else { @() }

    $newParentLines = @()
    $newParentLines += $preamble
    foreach ($core in $coreSections) { $newParentLines += $core.Lines }
    $newParentLines += @(
        ""
        "---"
        ""
        "## Extended Sections"
        ""
        "Additional deep-dive content has been moved to"
        "[$childName](./$childName) to keep this doc within the standard section structure."
        ""
        "Topics covered in the deep-dive doc:"
    )
    $newParentLines += $movedHeadings
    $newParentLines += ""

    if (-not $DryRun) {
        Set-Content -Path $childPath -Value ($childLines -join "`n") -NoNewline -Encoding UTF8
        Set-Content -Path $DocPath -Value ($newParentLines -join "`n") -NoNewline -Encoding UTF8
    }

    return @{
        Split          = $true
        ParentPath     = $DocPath
        ChildPath      = $childPath
        ExtractedCount = $extraSections.Count
        OriginalLines  = $originalCount
        NewParentLines = $newParentLines.Count
        ChildLines     = $childLines.Count
    }
}

function Test-ParentChildCompleteness {
    <#
    .SYNOPSIS
        For parent docs with child docs, aggregates section coverage across the family.
    .PARAMETER ParentDocPath
        Path to the parent doc.
    .PARAMETER RepoPath
        Repository root.
    .PARAMETER RequiredSections
        Array of section patterns. Defaults to PrimaryWorkflowSections.
    .OUTPUTS
        Hashtable with ParentDoc, ChildDocs, section coverage, MissingSections, Pass.
    #>
    param(
        [Parameter(Mandatory)][string]$ParentDocPath,
        [Parameter(Mandatory)][string]$RepoPath,
        [array]$RequiredSections
    )

    if (-not $RequiredSections -or $RequiredSections.Count -eq 0) {
        $RequiredSections = $script:PrimaryWorkflowSections
    }

    $result = @{
        ParentDoc       = $ParentDocPath
        ChildDocs       = @()
        ParentSections  = @()
        ChildSections   = @{}
        UnionSections   = @()
        TotalRequired   = $RequiredSections.Count
        TotalPresent    = 0
        MissingSections = @()
        Pass            = $false
    }

    if (-not (Test-Path $ParentDocPath)) { return $result }

    $parentContent = Get-Content $ParentDocPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $parentContent) { return $result }

    # ── Find sections present in parent ──
    $parentFound = @()
    foreach ($section in $RequiredSections) {
        if ($parentContent -match $section.Pattern) {
            $parentFound += $section.Name
        }
    }
    $result.ParentSections = $parentFound

    # ── Extract child doc paths from "## Child Docs" section ──
    $childPaths = @()
    if ($parentContent -match '(?ms)##\s*Child\s*Docs(.+?)(?=\n##\s|\z)') {
        $childSection = $Matches[1]
        # Match table rows: | path/to/child.md | ... | or markdown links [text](path.md)
        $childTableMatches = [regex]::Matches($childSection, '(?m)^\|\s*`?([^\|`]+\.md)`?\s*\|')
        foreach ($m in $childTableMatches) { $childPaths += $m.Groups[1].Value.Trim() }
        # Also match markdown links
        $childLinkMatches = [regex]::Matches($childSection, '\[.*?\]\(([^\)]+\.md)\)')
        foreach ($m in $childLinkMatches) { $childPaths += $m.Groups[1].Value.Trim() }
    }

    $resolvedChildren = [System.Collections.Generic.List[string]]::new()
    $childSectionsMap = @{}

    foreach ($childRelPath in $childPaths) {
        $childFullPath = Join-Path (Split-Path $ParentDocPath -Parent) $childRelPath
        if (-not (Test-Path $childFullPath)) {
            # Try from repo root
            $childFullPath = Join-Path $RepoPath $childRelPath
        }
        if (-not (Test-Path $childFullPath)) { continue }

        $resolvedChildren.Add($childFullPath)
        $childContent = Get-Content $childFullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $childContent) { continue }

        $childFound = @()
        foreach ($section in $RequiredSections) {
            if ($childContent -match $section.Pattern) {
                $childFound += $section.Name
            }
        }
        $childSectionsMap[$childFullPath] = $childFound
    }

    $result.ChildDocs = @($resolvedChildren)
    $result.ChildSections = $childSectionsMap

    # ── Build union of all found sections ──
    $unionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $parentFound) { [void]$unionSet.Add($s) }
    foreach ($childEntry in $childSectionsMap.GetEnumerator()) {
        foreach ($s in $childEntry.Value) { [void]$unionSet.Add($s) }
    }
    $result.UnionSections = @($unionSet)

    # ── Determine missing sections ──
    $missingSections = @()
    foreach ($section in $RequiredSections) {
        if (-not $unionSet.Contains($section.Name)) {
            $missingSections += $section.Name
        }
    }
    $result.MissingSections = $missingSections
    $result.TotalPresent   = $unionSet.Count
    $result.Pass           = ($missingSections.Count -eq 0)

    return $result
}

# ═══════════════════════════════════════════════════════════════
# EXPORTS
# ═══════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Build-DomainContracts',
    'Test-CompletenessGate',
    'Get-RemediationQueue',
    'Show-CompletenessReport',
    'Invoke-CompletenessGate',
    'Test-DocReferences',
    'Test-CodePointers',
    'Test-DocSize',
    'Split-OversizedDoc',
    'Test-ParentChildCompleteness'
)
