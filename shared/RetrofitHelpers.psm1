<#
.SYNOPSIS
    RetrofitHelpers.psm1 — Core logic for Run-Retrofit.ps1
.DESCRIPTION
    Upgrades existing playbook-generated docs to DAG-complete status without
    re-running the full pipeline. Provides testable functions for detection,
    layer tagging, navigation injection, registry rebuild, code pointer audit,
    and doc size checks.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\DocLayers.psm1" -Force
Import-Module "$PSScriptRoot\DocRegistry.psm1" -Force
Import-Module "$PSScriptRoot\CompletenessGate.psm1" -Force

# ═══════════════════════════════════════════════════════════════
# PLAYBOOK DETECTION
# ═══════════════════════════════════════════════════════════════

function Test-PlaybookPresence {
    <#
    .SYNOPSIS
        Score >= 3 from 5 signals indicates playbook output is present.
    .PARAMETER RepoPath
        Repository root path.
    .OUTPUTS
        Hashtable with Score, Signals (list of matched signal names), Pass.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath
    )

    $signals = @()
    $score = 0

    # Signal 1: .github/copilot-instructions.md exists and > 500 bytes
    $ciPath = Join-Path $RepoPath ".github" "copilot-instructions.md"
    if (Test-Path $ciPath) {
        $size = (Get-Item $ciPath).Length
        if ($size -gt 500) {
            $score++
            $signals += 'copilot-instructions.md (>500 bytes)'
        }
    }

    # Signal 2: Discovery_Manifest.md exists somewhere under docs/
    $docsDir = Join-Path $RepoPath "docs"
    $manifestFound = $false
    if (Test-Path $docsDir) {
        $manifests = @(Get-ChildItem -Path $docsDir -Filter "Discovery_Manifest.md" -Recurse -File -ErrorAction SilentlyContinue)
        if ($manifests.Count -gt 0) {
            $manifestFound = $true
            $score++
            $signals += 'Discovery_Manifest.md found'
        }
    }
    # Also check repo root directly
    if (-not $manifestFound) {
        $rootManifest = @(Get-ChildItem -Path $RepoPath -Filter "Discovery_Manifest.md" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($rootManifest.Count -gt 0) {
            $score++
            $signals += 'Discovery_Manifest.md found'
        }
    }

    # Signal 3: >= 3 workflow docs in any workflows/ subfolder
    $workflowDirs = @(Get-ChildItem -Path $RepoPath -Directory -Recurse -Filter "workflows" -ErrorAction SilentlyContinue)
    $totalWorkflowDocs = 0
    foreach ($wfDir in $workflowDirs) {
        $mdFiles = @(Get-ChildItem -Path $wfDir.FullName -Filter "*.md" -File -ErrorAction SilentlyContinue)
        $totalWorkflowDocs += $mdFiles.Count
    }
    if ($totalWorkflowDocs -ge 3) {
        $score++
        $signals += "workflow docs ($totalWorkflowDocs found)"
    }

    # Signal 4: doc_registry.md exists
    $registryFiles = @(Get-ChildItem -Path $RepoPath -Filter "doc_registry.md" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($registryFiles.Count -gt 0) {
        $score++
        $signals += 'doc_registry.md found'
    }

    # Signal 5: .github/skills/ has at least one .md file
    $skillsDir = Join-Path $RepoPath ".github" "skills"
    if (Test-Path $skillsDir) {
        $skillFiles = @(Get-ChildItem -Path $skillsDir -Filter "*.md" -File -ErrorAction SilentlyContinue)
        if ($skillFiles.Count -gt 0) {
            $score++
            $signals += "skills ($($skillFiles.Count) .md files)"
        }
    }

    return @{
        Score   = $score
        Signals = $signals
        Pass    = ($score -ge 3)
    }
}

# ═══════════════════════════════════════════════════════════════
# DOCS ROOT DETECTION
# ═══════════════════════════════════════════════════════════════

function Find-DocsRoot {
    <#
    .SYNOPSIS
        Auto-detect DocsRoot by finding Discovery_Manifest.md and using its parent.
    .PARAMETER RepoPath
        Repository root.
    .PARAMETER DocsRoot
        Explicit override (returned as-is if specified).
    .OUTPUTS
        String path to docs root, or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$DocsRoot
    )

    if ($DocsRoot -and (Test-Path $DocsRoot)) { return $DocsRoot }

    $manifests = @(Get-ChildItem -Path $RepoPath -Filter "Discovery_Manifest.md" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($manifests.Count -gt 0) {
        return $manifests[0].Directory.FullName
    }

    # Fallback: common docs dirs
    foreach ($candidate in @("docs\knowledge", "docs\agentKT", "docs")) {
        $p = Join-Path $RepoPath $candidate
        if (Test-Path $p) { return $p }
    }

    return $null
}

# ═══════════════════════════════════════════════════════════════
# PASS 1: LAYER TAGGING
# ═══════════════════════════════════════════════════════════════

function Invoke-LayerTagging {
    <#
    .SYNOPSIS
        Tag all untagged docs with layer frontmatter.
    .OUTPUTS
        Hashtable with Tagged, Skipped, Summary (L0/L1/L2/L3 counts).
    #>
    param(
        [Parameter(Mandatory)][string]$DocsRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$DryRun
    )

    $docLayers = @(Get-AllDocLayers -DocsRoot $DocsRoot -RepoPath $RepoPath)

    # Also scan .github/ for copilot-instructions.md, copilot-memory.md, skills/
    $githubDir = Join-Path $RepoPath ".github"
    if (Test-Path $githubDir) {
        $ghFiles = @(Get-ChildItem -Path $githubDir -Filter "*.md" -File -ErrorAction SilentlyContinue)
        $skillsDir = Join-Path $githubDir "skills"
        if (Test-Path $skillsDir) {
            $ghFiles += @(Get-ChildItem -Path $skillsDir -Filter "*.md" -File -ErrorAction SilentlyContinue)
        }
        foreach ($f in $ghFiles) {
            $alreadyIn = $docLayers | Where-Object { $_.FilePath -eq $f.FullName }
            if (-not $alreadyIn) {
                $classification = Get-DocLayer -FilePath $f.FullName -RepoPath $RepoPath
                $existingTag = Get-DocLayerTag -FilePath $f.FullName
                $docLayers += [PSCustomObject]@{
                    Layer       = $classification.Layer
                    Role        = $classification.Role
                    FilePath    = $f.FullName
                    RelPath     = $classification.RelPath
                    ExistingTag = $existingTag
                    Tagged      = ($null -ne $existingTag)
                }
            }
        }
    }

    $tagged = 0
    $skipped = 0

    foreach ($doc in $docLayers) {
        if ($doc.Tagged) {
            $skipped++
            continue
        }
        if (-not $DryRun) {
            Set-DocLayerTag -FilePath $doc.FilePath -Layer $doc.Layer -Role $doc.Role | Out-Null
        }
        $tagged++
    }

    $summary = Get-LayerSummary -DocLayers $docLayers

    return @{
        Tagged    = $tagged
        Skipped   = $skipped
        Summary   = $summary
        DocLayers = $docLayers
    }
}

# ═══════════════════════════════════════════════════════════════
# PASS 2: NAVIGATION GUIDE
# ═══════════════════════════════════════════════════════════════

function Invoke-NavigationGuide {
    <#
    .SYNOPSIS
        Build and inject Navigation Guide into Discovery_Manifest.md.
    .OUTPUTS
        Hashtable with Status ('injected', 'replaced', 'skipped'), ManifestPath.
    #>
    param(
        [Parameter(Mandatory)][string]$DocsRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [array]$DocLayers,
        [switch]$DryRun
    )

    if (-not $DocLayers -or $DocLayers.Count -eq 0) {
        $DocLayers = @(Get-AllDocLayers -DocsRoot $DocsRoot -RepoPath $RepoPath)
    }

    $guide = Build-NavigationGuide -DocLayers $DocLayers -RepoPath $RepoPath

    # Find Discovery_Manifest.md
    $manifestPath = Join-Path $DocsRoot "Discovery_Manifest.md"
    if (-not (Test-Path $manifestPath)) {
        $candidates = @(Get-ChildItem -Path $DocsRoot -Filter "Discovery_Manifest.md" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($candidates.Count -gt 0) { $manifestPath = $candidates[0].FullName }
        else {
            return @{ Status = 'no-manifest'; ManifestPath = $null }
        }
    }

    $content = Get-Content $manifestPath -Raw -Encoding UTF8

    $hasGuide = $content -match '(?m)^## Navigation Guide'

    if ($DryRun) {
        $status = if ($hasGuide) { 'would-replace' } else { 'would-inject' }
        return @{ Status = $status; ManifestPath = $manifestPath }
    }

    if ($hasGuide) {
        # Replace existing guide section (from ## Navigation Guide to next ## or EOF)
        $content = $content -replace '(?ms)## Navigation Guide.*?(?=\n## [^N]|\z)', ($guide + "`n")
        $status = 'replaced'
    }
    else {
        # Append guide section
        $content = $content.TrimEnd() + "`n" + $guide + "`n"
        $status = 'injected'
    }

    Set-Content $manifestPath -Value $content -NoNewline -Encoding UTF8
    return @{ Status = $status; ManifestPath = $manifestPath }
}

# ═══════════════════════════════════════════════════════════════
# PASS 3: REGISTRY REBUILD
# ═══════════════════════════════════════════════════════════════

function Invoke-RegistryRebuild {
    <#
    .SYNOPSIS
        Rebuild doc_registry.md deterministically.
    .OUTPUTS
        Hashtable from Build-DocRegistry.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$DocsRoot,
        [switch]$DryRun
    )

    if ($DryRun) {
        # In dry-run, gather stats without writing
        $controllers = @(Get-ControllerList -RepoPath $RepoPath)
        $allLayers = @(Get-AllDocLayers -DocsRoot $DocsRoot -RepoPath $RepoPath)
        $layerSummary = Get-LayerSummary -DocLayers $allLayers
        return @{
            TotalControllers = $controllers.Count
            Documented       = 0
            Undocumented     = $controllers.Count
            CoveragePct      = 0
            LayerSummary     = $layerSummary
            DocPath          = $null
            DryRun           = $true
        }
    }

    return Build-DocRegistry -RepoPath $RepoPath -DocsRoot $DocsRoot
}

# ═══════════════════════════════════════════════════════════════
# PASS 4: CODE POINTER AUDIT
# ═══════════════════════════════════════════════════════════════

function Invoke-CodePointerAudit {
    <#
    .SYNOPSIS
        Audit all code pointers in workflow and reference docs.
    .OUTPUTS
        Hashtable with TotalRefs, DeadRefs, DeadPct, Pass, AutoFixed, Details.
    #>
    param(
        [Parameter(Mandatory)][string]$DocsRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$AutoFix
    )

    $allDocs = @(Get-ChildItem -Path $DocsRoot -Filter "*.md" -Recurse -File -ErrorAction SilentlyContinue)
    # Also include .github docs
    $githubDir = Join-Path $RepoPath ".github"
    if (Test-Path $githubDir) {
        $allDocs += @(Get-ChildItem -Path $githubDir -Filter "*.md" -Recurse -File -ErrorAction SilentlyContinue)
    }

    $totalRefs = 0
    $totalDead = 0
    $details = @()
    $autoFixed = 0

    foreach ($doc in $allDocs) {
        $result = Test-CodePointers -DocPath $doc.FullName -RepoPath $RepoPath
        $totalRefs += $result.TotalRefs
        $totalDead += $result.DeadRefs

        if ($result.DeadRefs -gt 0) {
            $details += @{
                DocPath      = $doc.FullName
                DeadRefs     = $result.DeadRefs
                DeadRefPaths = $result.DeadRefPaths
            }

            if ($AutoFix) {
                $fixed = Repair-DeadRefs -DocPath $doc.FullName -DeadRefs $result.DeadRefPaths -RepoPath $RepoPath
                $autoFixed += $fixed
            }
        }
    }

    $deadPct = if ($totalRefs -gt 0) { [math]::Round(($totalDead / $totalRefs) * 100, 1) } else { 0 }

    return @{
        TotalRefs = $totalRefs
        DeadRefs  = $totalDead
        DeadPct   = $deadPct
        Pass      = ($deadPct -le 20)
        AutoFixed = $autoFixed
        Details   = $details
    }
}

function Repair-DeadRefs {
    <#
    .SYNOPSIS
        Attempt filesystem-based fixes for dead refs (case mismatches, moved files).
    #>
    param(
        [Parameter(Mandatory)][string]$DocPath,
        [Parameter(Mandatory)][array]$DeadRefs,
        [Parameter(Mandatory)][string]$RepoPath
    )

    $fixed = 0
    $content = Get-Content $DocPath -Raw -Encoding UTF8

    foreach ($ref in $DeadRefs) {
        $normalizedRef = $ref -replace '/', '\'
        $fileName = [System.IO.Path]::GetFileName($normalizedRef)
        if (-not $fileName) { continue }

        # Search for file with same name anywhere in repo
        $candidates = @(Get-ChildItem -Path $RepoPath -Filter $fileName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|bin|obj|vendor|dist)[\\/]' } |
            Select-Object -First 1)

        if ($candidates.Count -gt 0) {
            $newRelPath = $candidates[0].FullName.Replace('\', '/').Replace($RepoPath.Replace('\', '/') + '/', '')
            $escapedRef = [regex]::Escape($ref)
            $newContent = $content -replace $escapedRef, $newRelPath
            if ($newContent -ne $content) {
                $content = $newContent
                $fixed++
            }
        }
    }

    if ($fixed -gt 0) {
        Set-Content $DocPath -Value $content -NoNewline -Encoding UTF8
    }

    return $fixed
}

# ═══════════════════════════════════════════════════════════════
# PASS 5: DOC SIZE CHECK
# ═══════════════════════════════════════════════════════════════

function Invoke-DocSizeCheck {
    <#
    .SYNOPSIS
        Check all docs against size limits by type.
    .OUTPUTS
        Hashtable with Total, UnderLimit, Flagged, FlaggedNames, Details.
    #>
    param(
        [Parameter(Mandatory)][string]$DocsRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$AutoFix
    )

    $allDocs = @(Get-ChildItem -Path $DocsRoot -Filter "*.md" -Recurse -File -ErrorAction SilentlyContinue)
    $docLayers = @(Get-AllDocLayers -DocsRoot $DocsRoot -RepoPath $RepoPath)

    $total = 0
    $underLimit = 0
    $flagged = @()
    $details = @()

    foreach ($doc in $allDocs) {
        $total++
        $layerInfo = $docLayers | Where-Object { $_.FilePath -eq $doc.FullName } | Select-Object -First 1

        # Determine doc type from layer
        $docType = 'general'
        if ($layerInfo) {
            $docType = switch ($layerInfo.Layer) {
                'L3' { 'workflow' }
                'L2' {
                    if ($layerInfo.Role -eq 'decision-record') { 'adr' } else { 'reference' }
                }
                default { 'general' }
            }
        }

        $result = Test-DocSize -DocPath $doc.FullName -DocType $docType
        $details += $result

        if ($result.Status -eq 'OK') {
            $underLimit++
        }
        else {
            $flagged += [System.IO.Path]::GetFileName($doc.FullName)
        }
    }

    $recommendations = @()
    if ($AutoFix -and $flagged.Count -gt 0) {
        $recommendations += "Consider splitting these oversize docs: $($flagged -join ', ')"
    }

    return @{
        Total           = $total
        UnderLimit      = $underLimit
        Flagged         = $flagged.Count
        FlaggedNames    = $flagged
        Details         = $details
        Recommendations = $recommendations
    }
}

# ═══════════════════════════════════════════════════════════════
# REPORT GENERATION
# ═══════════════════════════════════════════════════════════════

function Build-RetrofitReport {
    <#
    .SYNOPSIS
        Generate the final retrofit report from pass results.
    .OUTPUTS
        Hashtable with Lines (array of strings), OverallStatus.
    #>
    param(
        [hashtable]$LayerResult,
        [hashtable]$NavResult,
        [hashtable]$RegistryResult,
        [hashtable]$PointerResult,
        [hashtable]$SizingResult,
        [switch]$DryRun
    )

    $lines = @()
    $lines += ''
    $lines += '🔧 Retrofit Report'
    $lines += '─────────────────────────────'
    $hasIssues = $false

    # Layer tags
    if ($LayerResult) {
        $s = $LayerResult.Summary
        $lines += "  Layer tags added:     $($LayerResult.Tagged) docs tagged (L0:$($s.L0), L1:$($s.L1), L2:$($s.L2), L3:$($s.L3))"
    }
    else {
        $lines += '  Layer tags added:     ❌ skipped'
    }

    # Navigation Guide
    if ($NavResult) {
        $icon = switch ($NavResult.Status) {
            'injected'     { '✅ injected' }
            'replaced'     { '✅ replaced' }
            'would-inject' { '⚠️ would inject (dry-run)' }
            'would-replace' { '⚠️ would replace (dry-run)' }
            'no-manifest'  { '❌ no manifest found' }
            default        { $NavResult.Status }
        }
        $lines += "  Navigation Guide:     $icon"
    }
    else {
        $lines += '  Navigation Guide:     ❌ skipped'
    }

    # Registry
    if ($RegistryResult) {
        if ($RegistryResult.DryRun) {
            $lines += "  Registry rebuilt:     ⚠️ dry-run ($($RegistryResult.TotalControllers) controllers detected)"
        }
        else {
            $lines += "  Registry rebuilt:     ✅ $($RegistryResult.TotalControllers) controllers, $($RegistryResult.CoveragePct)% coverage"
        }
    }
    else {
        $lines += '  Registry rebuilt:     ❌ skipped'
    }

    # Code pointers
    if ($PointerResult) {
        $verdict = if ($PointerResult.Pass) { 'PASS' } else { 'FAIL'; $hasIssues = $true }
        $autoStr = if ($PointerResult.AutoFixed -gt 0) { " (auto-fixed $($PointerResult.AutoFixed))" } else { '' }
        $lines += "  Code pointers:        $($PointerResult.TotalRefs) refs checked, $($PointerResult.DeadRefs) dead ($($PointerResult.DeadPct)%) — $verdict$autoStr"
    }
    else {
        $lines += '  Code pointers:        ❌ skipped'
    }

    # Doc sizing
    if ($SizingResult) {
        $lines += "  Doc sizing:           $($SizingResult.UnderLimit)/$($SizingResult.Total) under limit, $($SizingResult.Flagged) flagged"
        if ($SizingResult.Flagged -gt 0) { $hasIssues = $true }
    }
    else {
        $lines += '  Doc sizing:           ❌ skipped'
    }

    $lines += '─────────────────────────────'
    $overallStatus = if ($hasIssues) { '⚠️ Issues found' } else { '✅ Retrofit complete' }
    $lines += "  Status: $overallStatus"

    return @{
        Lines         = $lines
        OverallStatus = $overallStatus
        HasIssues     = $hasIssues
    }
}

# ─────────────────────────────────────────────
# Export all public functions
# ─────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Test-PlaybookPresence'
    'Find-DocsRoot'
    'Invoke-LayerTagging'
    'Invoke-NavigationGuide'
    'Invoke-RegistryRebuild'
    'Invoke-CodePointerAudit'
    'Invoke-DocSizeCheck'
    'Build-RetrofitReport'
    'Repair-DeadRefs'
)
