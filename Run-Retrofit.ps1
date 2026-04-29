<#
.SYNOPSIS
    Run-Retrofit.ps1 — Upgrade playbook-generated docs to DAG-complete status.
.DESCRIPTION
    Runs 5 passes to retrofit existing documentation:
    1. Layer Tagging — classify and tag all docs with L0/L1/L2/L3 frontmatter
    2. Navigation Guide — inject reading-chain table into Discovery_Manifest.md
    3. Registry Rebuild — deterministic doc_registry.md from source scan
    4. Code Pointer Audit — verify all file references resolve on disk
    5. Doc Size Check — enforce per-type line count limits

.PARAMETER RepoPath
    Path to the repository root.
.PARAMETER DocsRoot
    Docs folder (auto-detected from Discovery_Manifest.md if not specified).
.PARAMETER DryRun
    Preview changes without writing.
.PARAMETER AutoFix
    Enable filesystem-based fixes (dead ref renames, split recommendations).
.PARAMETER Commit
    Git commit after retrofit.
.PARAMETER CommitMessage
    Custom commit message.
.PARAMETER Only
    Run a specific pass only: layers, navigation, registry, pointers, sizing, all.

.EXAMPLE
    .\Run-Retrofit.ps1 -RepoPath "C:\Repo\MyRepo" -DryRun
.EXAMPLE
    .\Run-Retrofit.ps1 -RepoPath "C:\Repo\MyRepo" -Commit
.EXAMPLE
    .\Run-Retrofit.ps1 -RepoPath "C:\Repo\MyRepo" -Only pointers -AutoFix
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoPath,
    [string]$DocsRoot,
    [switch]$DryRun,
    [switch]$AutoFix,
    [switch]$Commit,
    [string]$CommitMessage = "chore: retrofit docs to DAG-complete (layer tags, registry, navigation)",
    [ValidateSet('layers', 'navigation', 'registry', 'pointers', 'sizing', 'all')]
    [string]$Only = 'all'
)

$ErrorActionPreference = "Stop"

# ── Import modules ──
Import-Module (Join-Path $PSScriptRoot "shared\MonkeyCommon.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "shared\RetrofitHelpers.psm1") -Force

Write-MonkeyBanner -Name "Doc Retrofit" -Emoji "🔧" -Version "1.0" -Tagline "Upgrade docs to DAG-complete"

# ══════════════════════════════════════════════════════════════════
#  PRE-CHECK — Detect playbook output
# ══════════════════════════════════════════════════════════════════

Write-Phase "PRE-CHECK" "Detecting playbook output"

$detection = Test-PlaybookPresence -RepoPath $RepoPath

if (-not $detection.Pass) {
    Write-Step "Score: $($detection.Score)/5 — below threshold of 3" "WARN"
    foreach ($sig in $detection.Signals) {
        Write-Step "  ✓ $sig" "OK"
    }
    Write-Host ""
    Write-Host "  No playbook output detected. Run playbook first." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Step "Playbook detected: score $($detection.Score)/5" "OK"
foreach ($sig in $detection.Signals) {
    Write-Step "  ✓ $sig" "OK"
}

# ── Auto-detect DocsRoot ──
$resolvedDocsRoot = Find-DocsRoot -RepoPath $RepoPath -DocsRoot $DocsRoot
if (-not $resolvedDocsRoot) {
    Write-Step "Could not locate docs root. Specify -DocsRoot." "ERROR"
    exit 1
}
Write-Step "Docs root: $resolvedDocsRoot" "OK"

if ($DryRun) {
    Write-Step "DRY RUN — no files will be modified" "WARN"
}

# ── Track pass results ──
$layerResult = $null
$navResult = $null
$registryResult = $null
$pointerResult = $null
$sizingResult = $null

# ══════════════════════════════════════════════════════════════════
#  PASS 1: LAYER TAGGING
# ══════════════════════════════════════════════════════════════════

if ($Only -eq 'layers' -or $Only -eq 'all') {
    Write-Phase "PASS 1" "Layer Tagging"

    $layerResult = Invoke-LayerTagging -DocsRoot $resolvedDocsRoot -RepoPath $RepoPath -DryRun:$DryRun
    $s = $layerResult.Summary
    Write-Step "Layer tags added: $($layerResult.Tagged) docs (L0:$($s.L0), L1:$($s.L1), L2:$($s.L2), L3:$($s.L3))" "OK"
    if ($layerResult.Skipped -gt 0) {
        Write-Step "Skipped $($layerResult.Skipped) already-tagged docs" "SKIP"
    }
}

# ══════════════════════════════════════════════════════════════════
#  PASS 2: NAVIGATION GUIDE
# ══════════════════════════════════════════════════════════════════

if ($Only -eq 'navigation' -or $Only -eq 'all') {
    Write-Phase "PASS 2" "Navigation Guide"

    $docLayers = if ($layerResult) { $layerResult.DocLayers } else { $null }
    $navResult = Invoke-NavigationGuide -DocsRoot $resolvedDocsRoot -RepoPath $RepoPath -DocLayers $docLayers -DryRun:$DryRun

    $navIcon = switch ($navResult.Status) {
        'injected'      { '✅ injected into Discovery_Manifest.md' }
        'replaced'      { '✅ replaced in Discovery_Manifest.md' }
        'would-inject'  { '⚠️ would inject (dry-run)' }
        'would-replace' { '⚠️ would replace (dry-run)' }
        'no-manifest'   { '❌ Discovery_Manifest.md not found' }
        default         { $navResult.Status }
    }
    Write-Step "Navigation Guide: $navIcon" "OK"
}

# ══════════════════════════════════════════════════════════════════
#  PASS 3: REGISTRY REBUILD
# ══════════════════════════════════════════════════════════════════

if ($Only -eq 'registry' -or $Only -eq 'all') {
    Write-Phase "PASS 3" "Registry Rebuild"

    $registryResult = Invoke-RegistryRebuild -RepoPath $RepoPath -DocsRoot $resolvedDocsRoot -DryRun:$DryRun

    if ($DryRun) {
        Write-Step "Registry: $($registryResult.TotalControllers) controllers detected (dry-run, not written)" "WARN"
    }
    else {
        Write-Step "Registry rebuilt: ✅ $($registryResult.TotalControllers) controllers, $($registryResult.CoveragePct)% coverage" "OK"
    }
}

# ══════════════════════════════════════════════════════════════════
#  PASS 4: CODE POINTER AUDIT
# ══════════════════════════════════════════════════════════════════

if ($Only -eq 'pointers' -or $Only -eq 'all') {
    Write-Phase "PASS 4" "Code Pointer Audit"

    $pointerResult = Invoke-CodePointerAudit -DocsRoot $resolvedDocsRoot -RepoPath $RepoPath -AutoFix:$AutoFix
    $verdict = if ($pointerResult.Pass) { 'PASS' } else { 'FAIL' }
    Write-Step "Code pointers: $($pointerResult.TotalRefs) refs checked, $($pointerResult.DeadRefs) dead ($($pointerResult.DeadPct)%) — $verdict" "$(if ($pointerResult.Pass) { 'OK' } else { 'WARN' })"

    if ($pointerResult.AutoFixed -gt 0) {
        Write-Step "Auto-fixed $($pointerResult.AutoFixed) refs" "OK"
    }
}

# ══════════════════════════════════════════════════════════════════
#  PASS 5: DOC SIZE CHECK
# ══════════════════════════════════════════════════════════════════

if ($Only -eq 'sizing' -or $Only -eq 'all') {
    Write-Phase "PASS 5" "Doc Size Check"

    $sizingResult = Invoke-DocSizeCheck -DocsRoot $resolvedDocsRoot -RepoPath $RepoPath -AutoFix:$AutoFix
    Write-Step "Doc sizing: $($sizingResult.UnderLimit)/$($sizingResult.Total) under limit, $($sizingResult.Flagged) flagged" "$(if ($sizingResult.Flagged -eq 0) { 'OK' } else { 'WARN' })"

    if ($sizingResult.FlaggedNames.Count -gt 0) {
        foreach ($name in $sizingResult.FlaggedNames) {
            Write-Step "  ⚠️ $name" "WARN"
        }
    }
    if ($sizingResult.Recommendations.Count -gt 0) {
        foreach ($rec in $sizingResult.Recommendations) {
            Write-Step "  💡 $rec" "INFO"
        }
    }
}

# ══════════════════════════════════════════════════════════════════
#  FINAL REPORT
# ══════════════════════════════════════════════════════════════════

$report = Build-RetrofitReport `
    -LayerResult $layerResult `
    -NavResult $navResult `
    -RegistryResult $registryResult `
    -PointerResult $pointerResult `
    -SizingResult $sizingResult `
    -DryRun:$DryRun

Write-Host ""
foreach ($line in $report.Lines) {
    $color = if ($line -match '✅') { 'Green' }
             elseif ($line -match '⚠️|FAIL') { 'Yellow' }
             elseif ($line -match '❌') { 'Red' }
             elseif ($line -match '─') { 'DarkGray' }
             elseif ($line -match '🔧') { 'Cyan' }
             else { 'White' }
    Write-Host $line -ForegroundColor $color
}
Write-Host ""

# ══════════════════════════════════════════════════════════════════
#  COMMIT (optional)
# ══════════════════════════════════════════════════════════════════

if ($Commit -and -not $DryRun) {
    Write-Phase "COMMIT" "Staging and committing retrofit changes"
    & git -C $RepoPath add -A 2>&1 | Out-Null
    $status = & git -C $RepoPath --no-pager status --porcelain 2>&1
    if ($status) {
        & git -C $RepoPath commit -m $CommitMessage 2>&1 | Out-Null
        Write-Step "Changes committed" "OK"
    }
    else {
        Write-Step "No changes to commit" "SKIP"
    }
}
