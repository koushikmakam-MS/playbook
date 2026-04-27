<#
.SYNOPSIS
    Cross-monkey question dedup using local pre-filter + LLM semantic merge.
.DESCRIPTION
    Loads questions from all monkeys, deduplicates using a 3-stage pipeline:
      Stage 1: Exact match (normalized text hash)
      Stage 2: Local fuzzy filter (Jaccard on same-file + same-category pairs)
      Stage 3: LLM semantic merge (Copilot CLI on candidate clusters only)
    Outputs patched question files + dedup-report.json.
.PARAMETER BenchmarkPath
    Path to benchmark-questions/ directory (or monkey output dir with *-questions.json).
.PARAMETER OutputPath
    Where to write dedup results. Defaults to BenchmarkPath/../dedup-results/
.PARAMETER JaccardThreshold
    Minimum Jaccard similarity to flag as candidate for LLM review. Default 0.60.
.PARAMETER DryRun
    Show what would be deduped without modifying files.
.PARAMETER SkipLLM
    Only run local stages (1+2), skip LLM stage 3. Good for testing thresholds.
.PARAMETER Model
    Copilot model to use. Default: auto-detect.
.PARAMETER MaxPerBatch
    Max candidate questions per LLM call. Default: 30.
#>

param(
    [Parameter(Mandatory)]
    [string]$BenchmarkPath,
    [string]$OutputPath,
    [double]$JaccardThreshold = 0.60,
    [switch]$DryRun,
    [switch]$SkipLLM,
    [string]$Model,
    [int]$MaxPerBatch = 30,
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

# Import shared module for Copilot calls
$sharedModule = Join-Path $PSScriptRoot "shared\MonkeyCommon.psm1"
if (Test-Path $sharedModule) {
    Import-Module $sharedModule -Force
}

# ══════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════

function Normalize-QuestionText {
    param([string]$Text)
    # Lowercase, strip punctuation, collapse whitespace
    $t = $Text.ToLower() -replace '[^\w\s]', '' -replace '\s+', ' '
    return $t.Trim()
}

function Get-WordBag {
    param([string]$Text)
    $normalized = Normalize-QuestionText $Text
    $words = ($normalized -split '\s+' | Where-Object { $_.Length -gt 2 }) | Sort-Object -Unique
    return $words
}

function Get-JaccardSimilarity {
    param([string[]]$A, [string[]]$B)
    if ($A.Count -eq 0 -or $B.Count -eq 0) { return 0 }
    $setA = [System.Collections.Generic.HashSet[string]]::new([string[]]$A)
    $setB = [System.Collections.Generic.HashSet[string]]::new([string[]]$B)
    $intersection = [System.Collections.Generic.HashSet[string]]::new($setA)
    $intersection.IntersectWith($setB)
    $union = [System.Collections.Generic.HashSet[string]]::new($setA)
    $union.UnionWith($setB)
    if ($union.Count -eq 0) { return 0 }
    return [Math]::Round($intersection.Count / $union.Count, 4)
}

function Normalize-EntryPoint {
    param([string]$Path)
    # Canonical: lowercase, forward slashes, trim leading ./ or .\
    $p = $Path.ToLower() -replace '\\', '/' -replace '^\./', ''
    return $p.Trim()
}

# Monkey priority order (earlier = higher priority = keep)
$MonkeyPriority = @{
    'rafiki'      = 1
    'abu'         = 2
    'diddy-kong'  = 3
    'donkey-kong' = 4
    'mojo-jojo'   = 5
    'marcel'      = 6
}

# ══════════════════════════════════════════════════════════════════
#  STAGE 0: LOAD ALL QUESTIONS
# ══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║       🔍 QUESTION DEDUP ENGINE                      ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Host "  [STAGE 0] Loading questions..." -ForegroundColor White

$questionFiles = Get-ChildItem $BenchmarkPath -Filter "*-questions.json" -File
if ($questionFiles.Count -eq 0) {
    Write-Host "  ERROR: No *-questions.json files found in $BenchmarkPath" -ForegroundColor Red
    exit 1
}

# Unified question pool with canonical IDs
$allQuestions = @()
$globalId = 0

foreach ($file in $questionFiles) {
    $monkeyName = $file.BaseName -replace '-questions$', ''
    $data = Get-Content $file.FullName -Raw | ConvertFrom-Json

    # Handle both {Questions: [...]} and [...] formats
    $questions = if ($data.Questions) { $data.Questions } else { @($data) }

    $qIndex = 0
    foreach ($q in $questions) {
        $qIndex++
        $globalId++
        $entryPoint = if ($q.EntryPoint) { Normalize-EntryPoint $q.EntryPoint } else { "unknown" }
        $category = if ($q.Category) { $q.Category.ToLower() } else { "auto" }
        $questionText = $q.Question

        $allQuestions += [PSCustomObject]@{
            Id            = "$monkeyName-Q$qIndex"
            GlobalId      = $globalId
            Monkey        = $monkeyName
            Category      = $category
            Question      = $questionText
            EntryPoint    = $entryPoint
            NormalizedText = Normalize-QuestionText $questionText
            WordBag       = Get-WordBag $questionText
            Hash          = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes((Normalize-QuestionText $questionText))
                )
            ).Replace("-", "").Substring(0, 16)
            Decision      = "KEEP"           # default: keep everything
            MergedInto    = $null
            Reason        = $null
            Stage         = $null
        }
    }
    Write-Host "    $monkeyName : $qIndex questions loaded" -ForegroundColor Gray
}

Write-Host "  Total: $($allQuestions.Count) questions from $($questionFiles.Count) monkeys" -ForegroundColor Green
Write-Host ""

# ══════════════════════════════════════════════════════════════════
#  STAGE 1: EXACT DEDUP (hash match)
# ══════════════════════════════════════════════════════════════════

Write-Host "  [STAGE 1] Exact dedup (normalized text hash)..." -ForegroundColor White

$hashGroups = $allQuestions | Group-Object Hash | Where-Object { $_.Count -gt 1 }
$stage1Removed = 0

foreach ($group in $hashGroups) {
    # Sort by monkey priority — keep the earliest monkey's version
    $sorted = $group.Group | Sort-Object { $MonkeyPriority[$_.Monkey] }
    $keeper = $sorted[0]

    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $dupe = $sorted[$i]
        $dupe.Decision = "REMOVED"
        $dupe.MergedInto = $keeper.Id
        $dupe.Reason = "Exact text match with $($keeper.Id)"
        $dupe.Stage = "exact"
        $stage1Removed++
    }
}

Write-Host "    Removed: $stage1Removed exact duplicates" -ForegroundColor $(if ($stage1Removed -gt 0) { "Yellow" } else { "Green" })

# ══════════════════════════════════════════════════════════════════
#  STAGE 2: LOCAL FUZZY FILTER (Jaccard on same-file + same-category)
# ══════════════════════════════════════════════════════════════════

Write-Host "  [STAGE 2] Local fuzzy filter (Jaccard >= $JaccardThreshold, same file)..." -ForegroundColor White

# Only consider questions still alive
$alive = $allQuestions | Where-Object { $_.Decision -eq "KEEP" }

# Group by canonical file only (cross-category comparison — LLM decides if different angles are dupes)
$fileGroups = $alive | Group-Object { $_.EntryPoint }

$candidateClusters = @()
$stage2Removed = 0

foreach ($fg in $fileGroups) {
    $members = @($fg.Group)
    if ($members.Count -lt 2) { continue }

    # Check if multiple monkeys contribute to this file
    $monkeyCount = ($members | Select-Object -ExpandProperty Monkey -Unique).Count

    if ($monkeyCount -ge 2) {
        # Multiple monkeys on same file — always send to LLM for semantic review
        # Split into sub-batches if too large
        if ($members.Count -le $MaxPerBatch) {
            $candidateClusters += ,@($members)
        } else {
            # Chunk into MaxPerBatch-sized groups
            for ($c = 0; $c -lt $members.Count; $c += $MaxPerBatch) {
                $chunk = @($members[$c..([Math]::Min($c + $MaxPerBatch - 1, $members.Count - 1))])
                if ($chunk.Count -ge 2) { $candidateClusters += ,@($chunk) }
            }
        }
    } else {
        # Same monkey, same file — use Jaccard for local dedup
        # Build adjacency: union-find for connected components
        $parent = @{}
        foreach ($m in $members) { $parent[$m.Id] = $m.Id }

        function Find-Root {
            param([string]$x)
            while ($parent[$x] -ne $x) {
                $parent[$x] = $parent[$parent[$x]]
                $x = $parent[$x]
            }
            return $x
        }

        function Union-Nodes {
            param([string]$a, [string]$b)
            $ra = Find-Root $a
            $rb = Find-Root $b
            if ($ra -ne $rb) { $parent[$ra] = $rb }
        }

        for ($i = 0; $i -lt $members.Count; $i++) {
            for ($j = $i + 1; $j -lt $members.Count; $j++) {
                $sim = Get-JaccardSimilarity -A $members[$i].WordBag -B $members[$j].WordBag
                if ($sim -ge $JaccardThreshold) {
                    Union-Nodes $members[$i].Id $members[$j].Id
                }
            }
        }

        $components = @{}
        foreach ($m in $members) {
            $root = Find-Root $m.Id
            if (-not $components[$root]) { $components[$root] = @() }
            $components[$root] += $m
        }

        foreach ($comp in $components.Values) {
            if ($comp.Count -lt 2) { continue }

            $avgSim = 0; $pairCount = 0
            for ($i = 0; $i -lt $comp.Count; $i++) {
                for ($j = $i + 1; $j -lt $comp.Count; $j++) {
                    $avgSim += Get-JaccardSimilarity -A $comp[$i].WordBag -B $comp[$j].WordBag
                    $pairCount++
                }
            }
            $avgSim = if ($pairCount -gt 0) { $avgSim / $pairCount } else { 0 }

            if ($avgSim -ge 0.85) {
                $sorted = $comp | Sort-Object { $MonkeyPriority[$_.Monkey] }
                $keeper = $sorted[0]
                for ($k = 1; $k -lt $sorted.Count; $k++) {
                    $sorted[$k].Decision = "REMOVED"
                    $sorted[$k].MergedInto = $keeper.Id
                    $sorted[$k].Reason = "High Jaccard ($([Math]::Round($avgSim, 2))) auto-merge"
                    $sorted[$k].Stage = "jaccard-auto"
                    $stage2Removed++
                }
            } else {
                $candidateClusters += ,@($comp)
            }
        }
    }
}

Write-Host "    Auto-merged: $stage2Removed (Jaccard >= 0.85)" -ForegroundColor $(if ($stage2Removed -gt 0) { "Yellow" } else { "Green" })
Write-Host "    LLM candidates: $($candidateClusters.Count) clusters ($($candidateClusters | ForEach-Object { $_.Count } | Measure-Object -Sum | Select-Object -ExpandProperty Sum) questions)" -ForegroundColor Cyan

# ══════════════════════════════════════════════════════════════════
#  STAGE 3: LLM SEMANTIC MERGE (Copilot CLI on candidate clusters)
# ══════════════════════════════════════════════════════════════════

$stage3Removed = 0

if (-not $SkipLLM -and $candidateClusters.Count -gt 0) {
    Write-Host "  [STAGE 3] LLM semantic merge ($($candidateClusters.Count) clusters)..." -ForegroundColor White

    # Batch clusters into groups of MaxPerBatch questions
    $batches = @()
    $currentBatch = @()
    $currentCount = 0

    foreach ($cluster in $candidateClusters) {
        if ($currentCount + $cluster.Count -gt $MaxPerBatch -and $currentBatch.Count -gt 0) {
            $batches += ,@($currentBatch)
            $currentBatch = @()
            $currentCount = 0
        }
        $currentBatch += ,@($cluster)
        $currentCount += $cluster.Count
    }
    if ($currentBatch.Count -gt 0) { $batches += ,@($currentBatch) }

    Write-Host "    Batches: $($batches.Count) (max $MaxPerBatch questions each)" -ForegroundColor Gray

    $batchNum = 0
    foreach ($batch in $batches) {
        $batchNum++
        Write-Host "    Batch $batchNum/$($batches.Count)..." -ForegroundColor Gray -NoNewline

        # Build prompt
        $promptLines = @()
        $promptLines += "You are a question dedup engine. Review these question clusters and decide which are true duplicates."
        $promptLines += ""
        $promptLines += "STRICT RULES:"
        $promptLines += "- MERGE only if questions have the SAME intent about the SAME code"
        $promptLines += "- Questions from different categories (e.g., 'security' vs 'auto') usually represent DIFFERENT perspectives — only merge if truly asking the exact same thing"
        $promptLines += "- KEEP both if questions ask from different angles even on the same file"
        $promptLines += "- NEVER invent new questions — merged text must combine existing wording only"
        $promptLines += "- When merging, keep the ID from the higher-priority monkey"
        $promptLines += "- Priority order: rafiki > abu > diddy-kong > donkey-kong > mojo-jojo > marcel"
        $promptLines += ""
        $promptLines += "CLUSTERS TO REVIEW:"

        $clusterNum = 0
        $batchQuestionMap = @{}
        foreach ($cluster in $batch) {
            $clusterNum++
            $promptLines += ""
            $promptLines += "--- Cluster $clusterNum (file: $($cluster[0].EntryPoint), category: $($cluster[0].Category)) ---"
            foreach ($q in $cluster) {
                $promptLines += "[$($q.Id)] ($($q.Monkey)): $($q.Question)"
                $batchQuestionMap[$q.Id] = $q
            }
        }

        $promptLines += ""
        $promptLines += 'OUTPUT: Return ONLY a JSON array. Each element:'
        $promptLines += '  {"clusterId": N, "keep": "id-to-keep", "mergeInto": ["ids-merged-into-keep"], "mergedQuestion": "combined text or null if no merge", "reason": "brief explanation"}'
        $promptLines += ""
        $promptLines += "If a cluster has no duplicates, return keep for each question with empty mergeInto."
        $promptLines += "Return ONLY the JSON array, no markdown fences, no explanation."

        $prompt = $promptLines -join "`n"

        # Call Copilot
        $copilotArgs = @("-p", $prompt)
        if ($Model) { $copilotArgs += @("-m", $Model) }
        if ($RepoPath) {
            Push-Location $RepoPath
        }

        try {
            $result = & copilot @copilotArgs 2>&1 | Out-String
        } catch {
            Write-Host " FAILED (copilot error)" -ForegroundColor Red
            if ($RepoPath) { Pop-Location }
            continue
        }

        if ($RepoPath) { Pop-Location }

        # Parse JSON from response (handle markdown fences)
        $jsonStr = $result
        if ($jsonStr -match '```(?:json)?\s*\n([\s\S]*?)\n```') {
            $jsonStr = $Matches[1]
        }
        # Try to find JSON array
        if ($jsonStr -match '(\[[\s\S]*\])') {
            $jsonStr = $Matches[1]
        }

        try {
            $decisions = $jsonStr | ConvertFrom-Json
        } catch {
            Write-Host " FAILED (JSON parse)" -ForegroundColor Red
            continue
        }

        # Apply decisions with validation
        $batchMerged = 0
        foreach ($d in $decisions) {
            if (-not $d.keep -or -not $d.mergeInto) { continue }
            $mergeTargets = @($d.mergeInto)
            if ($mergeTargets.Count -eq 0) { continue }

            $keeper = $batchQuestionMap[$d.keep]
            if (-not $keeper) { continue }

            foreach ($mid in $mergeTargets) {
                $mergeQ = $batchQuestionMap[$mid]
                if (-not $mergeQ) { continue }

                # VALIDATE: same file (category check removed — LLM decides cross-category merges)
                if ($mergeQ.EntryPoint -ne $keeper.EntryPoint) {
                    Write-Host " REJECTED cross-file merge: $mid -> $($d.keep)" -ForegroundColor Red
                    continue
                }

                $mergeQ.Decision = "REMOVED"
                $mergeQ.MergedInto = $d.keep
                $mergeQ.Reason = if ($d.reason) { $d.reason } else { "LLM semantic merge" }
                $mergeQ.Stage = "llm"
                $batchMerged++
                $stage3Removed++
            }

            # Update merged question text if provided
            if ($d.mergedQuestion -and $keeper) {
                $keeper.Question = $d.mergedQuestion
            }
        }

        Write-Host " $batchMerged merged" -ForegroundColor $(if ($batchMerged -gt 0) { "Yellow" } else { "Green" })
    }

    Write-Host "    LLM total: $stage3Removed merged" -ForegroundColor $(if ($stage3Removed -gt 0) { "Yellow" } else { "Green" })
} elseif ($SkipLLM) {
    Write-Host "  [STAGE 3] Skipped (-SkipLLM flag)" -ForegroundColor Gray
} else {
    Write-Host "  [STAGE 3] No candidates for LLM review" -ForegroundColor Green
}

# ══════════════════════════════════════════════════════════════════
#  REPORT
# ══════════════════════════════════════════════════════════════════

$totalRemoved = $stage1Removed + $stage2Removed + $stage3Removed
$surviving = $allQuestions | Where-Object { $_.Decision -eq "KEEP" }

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║       📊 DEDUP RESULTS                               ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ┌──────────────────────┬─────────┐" -ForegroundColor White
Write-Host "  │ Stage                │ Removed │" -ForegroundColor White
Write-Host "  ├──────────────────────┼─────────┤" -ForegroundColor White
Write-Host "  │ 1. Exact match       │ $('{0,7}' -f $stage1Removed) │" -ForegroundColor White
Write-Host "  │ 2. Jaccard auto      │ $('{0,7}' -f $stage2Removed) │" -ForegroundColor White
Write-Host "  │ 3. LLM semantic      │ $('{0,7}' -f $stage3Removed) │" -ForegroundColor White
Write-Host "  ├──────────────────────┼─────────┤" -ForegroundColor White
Write-Host "  │ TOTAL REMOVED        │ $('{0,7}' -f $totalRemoved) │" -ForegroundColor Yellow
Write-Host "  │ SURVIVING            │ $('{0,7}' -f $surviving.Count) │" -ForegroundColor Green
Write-Host "  └──────────────────────┴─────────┘" -ForegroundColor White
Write-Host ""

# Per-monkey breakdown
Write-Host "  Per-monkey impact:" -ForegroundColor White
$monkeyNames = $allQuestions | Select-Object -ExpandProperty Monkey -Unique | Sort-Object
foreach ($m in $monkeyNames) {
    $total = ($allQuestions | Where-Object { $_.Monkey -eq $m }).Count
    $removed = ($allQuestions | Where-Object { $_.Monkey -eq $m -and $_.Decision -eq "REMOVED" }).Count
    $pct = if ($total -gt 0) { [Math]::Round(($removed / $total) * 100, 1) } else { 0 }
    $bar = "█" * [Math]::Min([Math]::Floor($pct / 5), 20)
    Write-Host "    $($m.PadRight(14)) $($total.ToString().PadLeft(4)) → $($($total - $removed).ToString().PadLeft(4))  -$removed ($pct%) $bar" -ForegroundColor Gray
}

# ══════════════════════════════════════════════════════════════════
#  OUTPUT FILES
# ══════════════════════════════════════════════════════════════════

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path $BenchmarkPath -Parent) "dedup-results"
}
if (-not (Test-Path $OutputPath)) {
    New-Item $OutputPath -ItemType Directory -Force | Out-Null
}

# Full report
$report = [PSCustomObject]@{
    Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    InputCount    = $allQuestions.Count
    RemovedCount  = $totalRemoved
    SurvivingCount = $surviving.Count
    Stage1Exact   = $stage1Removed
    Stage2Jaccard = $stage2Removed
    Stage3LLM     = $stage3Removed
    JaccardThreshold = $JaccardThreshold
    SkipLLM       = $SkipLLM.IsPresent
    DryRun        = $DryRun.IsPresent
    Decisions     = $allQuestions | Select-Object Id, Monkey, Category, EntryPoint,
        @{N='QuestionPreview'; E={$_.Question.Substring(0, [Math]::Min(100, $_.Question.Length))}},
        Decision, MergedInto, Reason, Stage
}

$reportPath = Join-Path $OutputPath "dedup-report.json"
$report | ConvertTo-Json -Depth 5 | Set-Content $reportPath -Encoding UTF8
Write-Host "  Report: $reportPath" -ForegroundColor Green

# Patched per-monkey question files (surviving questions only)
if (-not $DryRun) {
    foreach ($m in $monkeyNames) {
        $monkeyQuestions = $allQuestions | Where-Object { $_.Monkey -eq $m -and $_.Decision -eq "KEEP" }
        $outputQuestions = $monkeyQuestions | ForEach-Object {
            [PSCustomObject]@{
                Question   = $_.Question
                EntryPoint = $_.EntryPoint
                Category   = $_.Category
            }
        }
        $patchedPath = Join-Path $OutputPath "$m-questions-deduped.json"
        @($outputQuestions) | ConvertTo-Json -Depth 3 | Set-Content $patchedPath -Encoding UTF8
        Write-Host "  Patched: $patchedPath ($($outputQuestions.Count) questions)" -ForegroundColor Gray
    }
} else {
    Write-Host "  [DRY RUN] No files written" -ForegroundColor Yellow
}

# Summary for pipeline consumption
Write-Host ""
Write-Host "  Done. Reduction: $totalRemoved/$($allQuestions.Count) ($([Math]::Round(($totalRemoved / [Math]::Max(1, $allQuestions.Count)) * 100, 1))%)" -ForegroundColor Cyan

# Return stats object for programmatic use
return [PSCustomObject]@{
    InputCount    = $allQuestions.Count
    RemovedCount  = $totalRemoved
    SurvivingCount = $surviving.Count
    Stage1        = $stage1Removed
    Stage2        = $stage2Removed
    Stage3        = $stage3Removed
    ReportPath    = $reportPath
    OutputPath    = $OutputPath
}
