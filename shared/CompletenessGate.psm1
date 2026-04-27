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
        [string]$ManifestPath
    )

    # Auto-discover manifest
    if (-not $ManifestPath) {
        $candidates = @(
            (Join-Path $RepoPath "docs\knowledge\Discovery_Manifest.md"),
            (Join-Path $RepoPath "docs\knowledge\discovery_manifest.md"),
            (Join-Path $RepoPath "docs\Discovery_Manifest.md")
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $ManifestPath = $c; break }
        }
    }

    if (-not $ManifestPath -or -not (Test-Path $ManifestPath)) {
        Write-Warning "Discovery Manifest not found at expected paths. No contracts generated."
        return @()
    }

    $content = Get-Content $ManifestPath -Raw -Encoding UTF8

    # Parse the Identified Domains table
    # Format: | # | Domain Name | Entry Points | Shared Impl | Doc Type | Workflow Doc |
    $contracts = @()
    $tableLines = $content -split "`n" | Where-Object { $_ -match '^\|\s*\d+\s*\|' }

    foreach ($line in $tableLines) {
        $cells = ($line -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($cells.Count -lt 6) { continue }

        $domainNum    = $cells[0].Trim()
        $domainName   = $cells[1].Trim()
        $entryPoints  = $cells[2].Trim()
        $sharedImpl   = $cells[3].Trim()
        $docType      = $cells[4].Trim().ToLower()
        $workflowDoc  = $cells[5].Trim()

        # Extract relative path from backticks: `workflows/01_User_Auth.md`
        $docRelPath = if ($workflowDoc -match '`([^`]+\.md)`') { $matches[1] } else { $workflowDoc }

        # Determine required sections based on doc type
        $requiredSections = switch -Regex ($docType) {
            'workflow'  { $script:PrimaryWorkflowSections }
            'reference' { $script:ReferenceDocSections }
            default     { $script:PrimaryWorkflowSections }  # default to workflow standard
        }

        # Resolve doc path: try exact match first, then fuzzy match by name keyword
        $docFullPath = Join-Path $RepoPath "docs\knowledge" $docRelPath
        $resolvedRelPath = $docRelPath

        if (-not (Test-Path $docFullPath)) {
            # Extract the descriptive part of the filename (after number prefix)
            $docFileName = [IO.Path]::GetFileNameWithoutExtension($docRelPath)
            $keyword = ($docFileName -replace '^\d+_', '')  # strip leading number_
            if ($keyword) {
                $workflowDir = Join-Path $RepoPath "docs\knowledge\workflows"
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

Follow the same format as existing workflow docs in docs/knowledge/workflows/.
Include: overview, entry points, request flow, sequence diagram, source files, config, telemetry, debugging, error scenarios.
Base all content on actual source code analysis — do not fabricate.
"@
            }
        }
        elseif ($result.Status -eq 'PARTIAL') {
            # Doc exists but missing sections
            foreach ($missing in $result.MissingSections) {
                $queue += [PSCustomObject]@{
                    Priority    = $priority
                    Type        = 'ADD_SECTION'
                    Domain      = $result.DomainName
                    TargetFile  = $result.DocRelativePath
                    SectionName = $missing.Name
                    SectionNum  = $missing.Number
                    Prompt      = @"
In the file '$($result.DocRelativePath)', add the missing section '## $($missing.Number). $($missing.Name)'.

This section should follow the same depth and format as other sections in the document.
Place it in numerical order relative to existing sections.
Base all content on actual source code analysis of the '$($result.DomainName)' domain — do not fabricate.
"@
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
        [switch]$Quiet
    )

    # Step 1: Build contracts from manifest
    $contracts = Build-DomainContracts -RepoPath $RepoPath

    if ($contracts.Count -eq 0) {
        Write-Warning "No domain contracts found. Completeness gate skipped."
        return @{
            GateResult       = [PSCustomObject]@{ Pass = $true; Verdict = "SKIP — no manifest found"; Results = @() }
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
# EXPORTS
# ═══════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Build-DomainContracts',
    'Test-CompletenessGate',
    'Get-RemediationQueue',
    'Show-CompletenessReport',
    'Invoke-CompletenessGate',
    'Test-DocReferences'
)
